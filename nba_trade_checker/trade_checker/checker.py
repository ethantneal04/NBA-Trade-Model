"""Narrow one-for-one *screening* engine, not an NBA approval/complete trade machine.

Supported: two standard contracts; verified straight-swap salary matching with
standard or expanded matching; basic signing moratoria, player consent, and
first/second apron hard caps. No aggregation, picks, cash, sign-and-trades,
preexisting TPEs, minimum salary exception, poison pill, BYC, or multiteam deals.

All amounts are whole USD. A PASS is only for rules supported by this module
and supplied verified snapshots. Review before using in production.
"""
from __future__ import annotations
from datetime import date
from calendar import monthrange
from fractions import Fraction
from .models import CheckResult, Contract, SeasonRules, Team, Trade


def add_calendar_months(d: date, months: int) -> date:
    year = d.year + (d.month - 1 + months) // 12
    month = (d.month - 1 + months) % 12 + 1
    return date(year, month, min(d.day, monthrange(year, month)[1]))


def signing_eligible_on(player: Contract) -> date | None:
    """Returns first tradable day for well-defined signing types.

    More unusual signing events are handled as NEEDS_REVIEW by caller.
    """
    if player.signed_on is None or player.signing_type is None:
        return None
    d = player.signed_on
    if player.signing_type == "ordinary_fa":
        return max(add_calendar_months(d, 3), date(d.year, 12, 15))
    if player.signing_type == "bird_raise":
        if player.bird_raise_over_120pct_and_over_cap is None:
            return None
        if player.bird_raise_over_120pct_and_over_cap:
            return max(add_calendar_months(d, 3), date(d.year + (d.month > 1), 1, 15))
        return max(add_calendar_months(d, 3), date(d.year, 12, 15))
    if player.signing_type in ("rookie", "two_way"):
        from datetime import timedelta
        return d + timedelta(days=30)
    return None


def _validate_player(p: Contract, trading_on: date, failures: list[str], review: list[str]) -> None:
    prefix = f"Player {p.player_id}: "
    if p.salary < 0:
        failures.append(prefix + "negative salary")
    if p.contract_type != "standard":
        review.append(prefix + "nonstandard contract outside V1 scope")
    if not p.verified:
        review.append(prefix + "contract/restriction details not verified")
    if p.signed_on is None or p.signing_type is None:
        review.append(prefix + "signing date/type not recorded")
    else:
        first = signing_eligible_on(p)
        if first is None:
            review.append(prefix + "signing moratorium requires manual assessment")
        elif trading_on < first:
            failures.append(prefix + f"signing moratorium through {first.isoformat()}")
    if p.restricted_until is None:
        review.append(prefix + "extension/renegotiation/trade restriction end date unknown")
    elif trading_on < p.restricted_until:
        failures.append(prefix + f"restricted from trade until {p.restricted_until.isoformat()}")
    if p.consent_required is None:
        review.append(prefix + "consent requirement unverified")
    elif p.consent_required and p.consent_given is False:
        failures.append(prefix + "required consent refused")
    elif p.consent_required and p.consent_given is not True:
        review.append(prefix + "required consent unconfirmed")
    if p.outgoing_trade_salary is None or p.incoming_trade_salary is None:
        review.append(prefix + "adjusted trade salary missing (kickers/BYC/guarantees/etc.)")
    elif p.outgoing_trade_salary < 0 or p.incoming_trade_salary < 0:
        failures.append(prefix + "negative matching salary")


def _matching(team: Team, outgoing: Contract, incoming: Contract,
              post_apron: int, rules: SeasonRules) -> tuple[str | None, bool]:
    """Return (legal acquisition method, requires_first_apron_hard_cap).

    Standard + expanded only. The second boolean records the hard cap created
    by use of the expanded method; matching amounts must already be adjusted.
    """
    s, i = outgoing.outgoing_trade_salary, incoming.incoming_trade_salary
    if s is None or i is None:
        return None, False
    allowance = rules.matching_allowance if post_apron <= rules.first_apron else 0
    if i <= s + allowance:
        return "standard_tpe", False
    # Cap-room exceptions, existing TPE balances, and other acquisition routes
    # are deliberately excluded from this V1; those trades need review.
    # Expanded: max(min(2S+250k, S + 7.5M*C/C0), 1.25S+250k).
    # Work in rationals to avoid floating-point boundary mistakes.
    flat = Fraction(7_500_000 * rules.salary_cap, rules.reference_cap_2023_24)
    expanded = max(min(Fraction(2*s + allowance), Fraction(s) + flat),
                   Fraction(5*s, 4) + allowance)
    if i <= expanded and post_apron <= rules.first_apron:
        return "expanded_tpe", True
    return None, False


def check_trade(trade: Trade, rules: SeasonRules | None = None) -> CheckResult:
    rules = rules or SeasonRules()
    failures: list[str] = []
    review: list[str] = []
    methods: dict[str, str] = {}
    after: dict[str, dict[str, int]] = {}

    a, b, pa, pb = trade.team_a, trade.team_b, trade.player_a, trade.player_b
    if a.team_id == b.team_id:
        failures.append("Trade must involve two distinct teams")
    if pa.player_id == pb.player_id:
        failures.append("Same player appears on both sides")
    if pa.team_id != a.team_id or pb.team_id != b.team_id:
        failures.append("Player ownership does not match sending team")
    if trade.window_verified_open is False:
        failures.append("Trade window is closed")
    elif trade.window_verified_open is not True:
        review.append("Trade window/deadline not independently verified")
    if trade.contains_other_assets or trade.special_transaction:
        review.append("Draft picks, cash, other assets or special transaction outside V1 scope")

    for p in (pa, pb):
        _validate_player(p, trade.on, failures, review)

    for team, outgoing, incoming in ((a, pa, pb), (b, pb, pa)):
        key = team.team_id
        if min(team.team_salary, team.apron_salary, team.roster_standard) < 0:
            failures.append(f"{key}: negative pretrade team values")
        if not team.salary_verified or not team.hard_caps_verified:
            review.append(f"{key}: cap/apron/hard-cap figures not verified")
        if not team.roster_verified:
            review.append(f"{key}: standard roster count not verified")
        # Only valid when provided salaries are verified as applicable cap/apron
        # salary changes. Trade kicker or different adjusted apron treatment
        # would require review and a more general salary evaluator.
        new_team_salary = team.team_salary - outgoing.salary + incoming.salary
        new_apron_salary = team.apron_salary - outgoing.salary + incoming.salary
        after[key] = {"team_salary": new_team_salary, "apron_salary": new_apron_salary,
                      "roster_standard": team.roster_standard}
        if new_team_salary < 0 or new_apron_salary < 0:
            failures.append(f"{key}: impossible negative posttrade salary")
        if team.hard_cap_first and new_apron_salary > rules.first_apron:
            failures.append(f"{key}: violates existing first-apron hard cap")
        if team.hard_cap_second and new_apron_salary > rules.second_apron:
            failures.append(f"{key}: violates existing second-apron hard cap")
        if team.roster_standard > 15:
            failures.append(f"{key}: over standard roster maximum (15)")
        if team.roster_standard < 14:
            review.append(f"{key}: below usual roster minimum; temporary exceptions must be checked")
        method, creates_first_hard_cap = _matching(team, outgoing, incoming, new_apron_salary, rules)
        if method:
            methods[key] = method
        elif outgoing.outgoing_trade_salary is not None and incoming.incoming_trade_salary is not None:
            # Other valid methods may exist. No false 'ineligible' claim.
            review.append(f"{key}: no standard/expanded method; other exceptions or salary adjustments may apply")
        if creates_first_hard_cap and new_apron_salary > rules.first_apron:
            failures.append(f"{key}: expanded match violates first-apron hard cap")

    # Missing data never yields a false ELIGIBLE. A proven hard failure wins.
    status = "INELIGIBLE" if failures else ("NEEDS_REVIEW" if review else "ELIGIBLE")
    return CheckResult(status=status, failures=failures, review=review,
                       methods=methods, after=after)

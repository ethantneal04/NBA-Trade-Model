from datetime import date
from dataclasses import replace
from trade_checker import Contract, Team, Trade, check_trade


def p(pid, team, salary, **kw):
    return Contract(player_id=pid, team_id=team, salary=salary,
                    outgoing_trade_salary=salary, incoming_trade_salary=salary,
                    signed_on=date(2025, 7, 1), signing_type="ordinary_fa",
                    restricted_until=date(2025, 7, 1), consent_required=False,
                    verified=True, **kw)


def t(id, sal, apron=None, **kw):
    return Team(team_id=id, team_salary=sal, apron_salary=sal if apron is None else apron,
                roster_standard=15, salary_verified=True, roster_verified=True,
                hard_caps_verified=True, **kw)


def example(a_salary=20_000_000, b_salary=20_000_000,
            a_team_salary=175_000_000, b_team_salary=175_000_000):
    return Trade(on=date(2026, 11, 16), team_a=t("AAA", a_team_salary),
                 player_a=p("p1", "AAA", a_salary),
                 team_b=t("BBB", b_team_salary),
                 player_b=p("p2", "BBB", b_salary), window_verified_open=True)


def test_equal_salary():
    r = check_trade(example())
    assert r.status == "ELIGIBLE"
    assert r.methods == {"AAA": "standard_tpe", "BBB": "standard_tpe"}


def test_expanded_match_below_first_apron():
    # A gets $15M for $10M: expanded needed. B gets $10M for $15M.
    r = check_trade(example(a_salary=10_000_000, b_salary=15_000_000))
    assert r.status == "ELIGIBLE"
    assert r.methods["AAA"] == "expanded_tpe"


def test_no_fabricated_exception():
    # Increased salary would put A above first apron: no expanded TPE.
    r = check_trade(example(a_salary=10_000_000, b_salary=15_000_000,
                            a_team_salary=208_000_000))
    assert r.status == "NEEDS_REVIEW"  # some other documented exception could apply
    assert "AAA" not in r.methods


def test_hard_cap_failure():
    tr = example(a_salary=10_000_000, b_salary=15_000_000,
                 a_team_salary=207_000_000)
    tr = replace(tr, team_a=replace(tr.team_a, hard_cap_first=True))
    assert check_trade(tr).status == "INELIGIBLE"


def test_signing_moratorium():
    tr = example()
    pl = replace(tr.player_a, signed_on=date(2026, 9, 20))
    tr = replace(tr, player_a=pl)
    result = check_trade(tr)
    assert result.status == "INELIGIBLE"
    assert any('moratorium' in x for x in result.failures)


def test_missing_contract_verification():
    tr = example()
    assert check_trade(replace(tr, player_a=replace(tr.player_a, verified=False))).status == "NEEDS_REVIEW"


def test_missing_consent():
    tr = example()
    assert check_trade(replace(tr, player_a=replace(tr.player_a, consent_required=True, consent_given=None))).status == "NEEDS_REVIEW"


def test_wrong_team():
    tr = example()
    assert check_trade(replace(tr, player_a=replace(tr.player_a, team_id="WRONG"))).status == "INELIGIBLE"


def test_nonstandard_contract_review():
    tr = example()
    assert check_trade(replace(tr, player_a=replace(tr.player_a, contract_type="two_way"))).status == "NEEDS_REVIEW"


def test_closed_window():
    tr = example()
    assert check_trade(replace(tr, window_verified_open=False)).status == "INELIGIBLE"

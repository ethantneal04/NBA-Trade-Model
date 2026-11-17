from __future__ import annotations
from dataclasses import dataclass, field
from datetime import date
from typing import Literal

Status = Literal["ELIGIBLE", "INELIGIBLE", "NEEDS_REVIEW"]

@dataclass(frozen=True)
class SeasonRules:
    season: str = "2026-27"
    salary_cap: int = 164_961_000
    first_apron: int = 209_015_000
    second_apron: int = 221_686_000
    reference_cap_2023_24: int = 136_021_000
    matching_allowance: int = 250_000

@dataclass(frozen=True)
class Contract:
    player_id: str
    team_id: str
    salary: int  # verified current-year salary amount for team cap/apron delta
    outgoing_trade_salary: int | None = None # verified CBA matching salary (may differ)
    incoming_trade_salary: int | None = None # verified acquiring-team CBA matching salary
    contract_type: Literal["standard", "two_way", "ten_day", "other"] = "standard"
    signed_on: date | None = None
    signing_type: Literal["ordinary_fa", "bird_raise", "rookie", "two_way", "other"] | None = None
    bird_raise_over_120pct_and_over_cap: bool | None = None
    restricted_until: date | None = None  # verified later trade restriction end date
    consent_required: bool | None = None
    consent_given: bool | None = None
    verified: bool = False  # accurate contract facts & restrictive provisions verified

@dataclass(frozen=True)
class Team:
    team_id: str
    team_salary: int   # verified pretrade cap salary (not only sum of active salaries)
    apron_salary: int  # verified pretrade apron salary
    roster_standard: int
    hard_cap_first: bool = False
    hard_cap_second: bool = False
    available_cap_room: int | None = None  # optional; verified if supplied
    salary_verified: bool = False
    roster_verified: bool = False
    hard_caps_verified: bool = False
    cap_room_verified: bool = False

@dataclass(frozen=True)
class Trade:
    on: date
    team_a: Team
    player_a: Contract  # A sends to B
    team_b: Team
    player_b: Contract  # B sends to A
    window_verified_open: bool | None = None
    # This V1 disallows special transactions, picks/cash, and preexisting TPE usage.
    contains_other_assets: bool = False
    special_transaction: bool = False

@dataclass
class CheckResult:
    status: Status
    failures: list[str] = field(default_factory=list)
    review: list[str] = field(default_factory=list)
    methods: dict[str, str] = field(default_factory=dict)
    after: dict[str, dict[str, int]] = field(default_factory=dict)

    def as_dict(self) -> dict:
        return {"status": self.status, "failures": self.failures,
                "needs_review": self.review, "matching_methods": self.methods,
                "post_trade": self.after}

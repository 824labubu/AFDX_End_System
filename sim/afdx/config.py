"""所有数值仅为 TB_ONLY_DEFAULT，不冻结系统参数。"""

from dataclasses import dataclass


@dataclass(frozen=True)
class TestConfig:
    # TB_ONLY_DEFAULT: 独立测试时钟和测试期限。
    system_clock_ns: int = 20
    gmii_clock_ns: int = 8
    reset_cycles: int = 5
    operation_timeout_us: int = 50
    max_stall_cycles: int = 2048
    gmii_ifg_cycles: int = 12  # documented GMII byte-cycle profile; not AFDX BAG


TB_ONLY_DEFAULT = TestConfig()

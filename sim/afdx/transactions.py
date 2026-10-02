"""应用字节流事务；不解释协议载荷。"""

from dataclasses import dataclass


@dataclass(frozen=True)
class AppTransaction:
    payload: bytes
    src_udp: int
    dst_udp: int
    application_port: int
    transaction_id: str = ""

    def __post_init__(self):
        # 拷贝载荷，防止发送期间被调用方修改。
        if not isinstance(self.payload, (bytes, bytearray, memoryview)):
            raise TypeError("payload must be bytes, bytearray or memoryview")
        object.__setattr__(self, "payload", bytes(self.payload))
        if not self.payload:
            raise ValueError("empty payload has no last-byte handshake")
        for name, width in (("src_udp", 16), ("dst_udp", 16), ("application_port", 8)):
            value = getattr(self, name)
            if not isinstance(value, int) or not 0 <= value < (1 << width):
                raise ValueError(f"{name} must fit unsigned {width} bits")

    def __len__(self):
        return len(self.payload)

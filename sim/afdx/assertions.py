"""只检查流接口契约，不检查协议字段。"""

from dataclasses import dataclass


@dataclass(frozen=True)
class StreamSample:
    valid: int
    ready: int
    data: int
    last: int
    src_udp: int
    dst_udp: int
    application_port: int

    @property
    def beat(self):
        return (self.data, self.last, self.src_udp, self.dst_udp, self.application_port)

    @property
    def metadata(self):
        return (self.src_udp, self.dst_udp, self.application_port)


class StreamAssertions:
    def __init__(self, name):
        self.name = name
        self.clear()

    def clear(self):
        self.stalled_beat = None
        self.message_metadata = None

    def check(self, sample):
        # 未被接收的字节必须保持 valid、数据和元信息。
        assert not sample.last or sample.valid, f"{self.name}: last without valid"
        if self.stalled_beat is not None:
            assert sample.valid and sample.beat == self.stalled_beat, (
                f"{self.name}: beat changed under backpressure"
            )
        if sample.valid:
            if self.message_metadata is None:
                self.message_metadata = sample.metadata
            assert sample.metadata == self.message_metadata, (
                f"{self.name}: metadata changed within message"
            )
        self.stalled_beat = sample.beat if sample.valid and not sample.ready else None
        if sample.valid and sample.ready and sample.last:
            self.message_metadata = None

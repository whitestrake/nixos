import importlib.util
import pathlib
import tempfile

spec = importlib.util.spec_from_file_location(
    "probe", pathlib.Path(__file__).with_name("cache-chunk-probe.py")
)
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)
with tempfile.TemporaryDirectory() as d:
    p = pathlib.Path(d) / "image"
    p.write_bytes(b"abcdefghab")
    assert [(o, b) for _, o, b in probe.chunks(p, 4)] == [
        (0, b"abcd"),
        (4, b"efgh"),
        (8, b"ab"),
    ]
a = dict(sha256="a", bytes=4, compressedBytes=3)
b = dict(sha256="b", bytes=2, compressedBytes=1)
r = probe.compare({"chunks": [a]}, {"chunks": [a, a, b]})
assert r == dict(
    chunks=3,
    uniqueChunks=2,
    newUniqueChunks=1,
    logicalBytes=10,
    fullUniqueCompressedBytes=4,
    newUniqueCompressedBytes=1,
)
print("Chunk boundaries, duplicate reuse and byte accounting passed")

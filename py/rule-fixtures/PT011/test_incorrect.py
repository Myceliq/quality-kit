import pytest


def test_parse():
    with pytest.raises(ValueError):
        int("x")

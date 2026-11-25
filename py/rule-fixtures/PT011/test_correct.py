import pytest


def test_parse():
    with pytest.raises(ValueError, match="invalid literal"):
        int("x")

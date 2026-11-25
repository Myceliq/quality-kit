import pytest


def test_parse():
    text = "x"
    with pytest.raises(ValueError, match="invalid literal"):
        int(text)

import pytest


def test_parse():
    with pytest.raises(ValueError, match="invalid literal"):
        text = "x"
        int(text)

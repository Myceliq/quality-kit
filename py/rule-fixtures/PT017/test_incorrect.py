def test_parse():
    try:
        int("x")
    except ValueError as e:
        assert "invalid literal" in str(e)

def check(x: int) -> int:
    if x < 0:
        raise ValueError("negative")
    else:
        return x

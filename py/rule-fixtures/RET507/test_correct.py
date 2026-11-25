def evens(items: list[int]) -> list[int]:
    out = []
    for i in items:
        if i % 2:
            continue
        out.append(i)
    return out

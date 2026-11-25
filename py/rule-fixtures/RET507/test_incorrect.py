def evens(items: list[int]) -> list[int]:
    out = []
    for i in items:
        if i % 2:
            continue
        else:
            out.append(i)
    return out

def show_until(items: list[int], stop: int) -> None:
    for i in items:
        if i == stop:
            break
        else:
            print(i)

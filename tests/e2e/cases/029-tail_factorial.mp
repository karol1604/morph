fact_iter : Int × Int -> Int
fact_iter n acc => {
    if n <= 1 then acc
    else fact_iter(n - 1, acc * n)
}

fact : Int -> Int
fact n => fact_iter(n, 1)

fact(6)

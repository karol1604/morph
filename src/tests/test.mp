count_helper : Int × Int -> Int
count_helper n acc => {
    printInt(acc)
    if n <= 0 then acc
    else count_helper(n - 1, acc + 1)
}

count : Int -> Int
count n => count_helper(n, 0)

fact : Int -> Int
fact n => {
    printInt(n)
    if n <= 0 then 1
    else n * fact(n - 1)
}

printInt(count(20))

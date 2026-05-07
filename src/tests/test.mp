count : Int -> Int
count n => if n <= 0 then 0 else 1 + count(n - 1)

count(255 * 10000)

---
active: false
layout: post
title: ""
subtitle: ""
description: ""
date: 2024-04-20 00:00:00
background: ''
---

# Binary Search

## Base Algo

```js
let [lo, hi] = [0, nums.length]

while(lo < hi) {
  let mid = (lo >> 1) + (hi >> 1)

  if(nums[mid] === target) {
    return mid
  }

  if(target > nums[mid]) {
    hi = mid
  } else {
    lo = mid + 1
  }

  return -1
}

// recurssion

bs(nums, target) => {
  return f(lo, hi) => {
    if(lo < hi) return -1

    let mid = (lo >> 1) + (hi >> 1)
    if(target === nums[mid]) return mid;

    if(target > nums[mid]) return f(arr, target, mid + 1, hi)
    return f(arr, target, lo, mid - 1)
  }
}
```

## Bisect Left/Right

The idea is to keep moving, as long as `target` `<= or >=`  nums[mid]


*Bisect Left*:

```js
while(lo < hi) {
  let mid = (lo + hi) >> 1; // use the previous one for prevent overflow but cooler

  if(target <= nums[mid]) {
    hi = mid
  } else {
    lo = mid + 1
  }
}
```

*Bisect Right*:

```js
while(lo < hi) {
  let mid = (hi + lo) >> 1 // you could also do, lo + (hi - lo)/2

  if(target >= nums[mid]) {
    lo = mid + 1
  } else {
    hi = mid
  }
}
```

_Key takeaway, lo < hi, hi = mid, lo = mid + 1, this pattern never changes. 


## Minimum of Maximum

While distributing N items amongst Y boxes(or people or whatevs),
find the maximum or minimum for each Y.

The core idea is to assume a possibleMax or possibleMin as nums[mid] and adjust the mid based on criteria.

> Using floor or ceil in the mid point calculation depends on the reality of the scenario.

- Assume we want to distribute d items to each of Y boxes
- Calculate the sum of items required, as sum(y/d for y in Y)
- Check if it matches the given target, if not adjust the window

*Base Template*:

```js

let [minItems, maxItems] = [0, Math.max(...items)]

// Each box receives (y = ) possibleItemsCount number of items
// total number of boxes is X/y , where X is number of boxes available
let possibleTotalBoxes = (possibleItemsCount) => items.reduce((acc, X) => acc + Math.floor(X/possibleItemsCount), 0)

while(minItems < maxItems) {
  let possibleItemsCount = Math.floor((maxItems + minItems) / 2)

  if(possibleTotalBoxes(possibleItemsCount) > N) {
    minItems = possibleItemsCount + 1
  } else {
    maxItem = possibleItemsCount
  }
}
```

*Minimize max items to put in store*:

```js
  let [minItems, maxItems] = [1, Math.max(...quantities)]
  const totalShopsReqr = (y) => quantities.reduce((acc, X) => acc + Math.ceil(X / y), 0)

  while (minItems < maxItems) {
    // floor because, if we use ceil(11/3) it would mean we need to have 12 items
    // otherwise 2 stores get 4 each, and one gets 3. 
    // the question requires us to minimize max number of product

    let possibleMaxPerShop = Math.floor((minItems + maxItems) / 2)

    // we want to minimize the sum, to we need to keep looking
    // to see if there is a smaller value, like bisec_left
    if (totalShopsReqr(possibleMaxPerShop) > n) {
      minItems = possibleMaxPerShop + 1
    } else {
      maxItems = possibleMaxPerShop
    }
  }

  return minItems;
```

*Maximum Candies:

```js
let [minCandi, maxCandi] = [0, Math.max(...candies)];
    let totalStudents = (y) => candies.reduce((acc, X) => acc + Math.floor(X/y), 0)

    while(minCandi < maxCandi) {
        // we want to maximize the candy distribuion, so
        // for floor(11/3) we get only 3 candies per student, but we can do better
        // 2 can get 4 candies, and 1 can get 3, exhausting all 11
        let possibleMax = Math.ceil((maxCandi + minCandi)/2);

        // if the total number of students possible is equal to k
        // we can consider it as a viable solution unless something greater comes up
        // if we had to minimize it, we would have to move the max candies to the left
        // so explore lower values
        if(totalStudents(possibleMax) >= k) {
            minCandi = possibleMax
        } else {
            maxCandi = possibleMax - 1
        }
    }
```

# Prefix Sum

The base idea is to solve for range queries on sub-arrays of the array. It comes as an optimization
in places, where calculating cumulative result needs a re-iteration, starting or ending from the present index.

```js
for(let i = 0; i < nums.length; i++) {
  let sumFromHere = 0;
  for (let j = i; j < nums.length; j++) {
    sumFromHere += nums[j]
  }
}

// or
for(let i = 0; i < nums.length; i++) {
  for (let j = nums.length - 1; j >= i; j--) {}
}
```

With prefix sum, keep a track of the sum upto that point.
So the sum between two points becomes: `prefix[i] - prefix[j]`

*Total number of subarray Sum Equals K*

```js
let prefix = nums.reduce((acc, v) => acc.concat(acc.at(-1) + v), [0]).slice(1)

// rest of the problem reduces to two sum.
// except we keep track of count

let diffcountMap = new Map(), count = 0;

// for a difference of 0, we have 1 subarray
// this handles negative numbers, like arr = [6, 1, 2, -8]
diffcountMap.set(0, 1)


for(let i = 0; i < prefix.length; i++) {
  let diff = prefix[i] - K
  
  let countTillDiff = diffcounMap.get(diff) || 0

  if(diffcountMap.has(diff)) {
    count += countTillDiff
  }

  // at this point, we need to keep track of the
  // present count, for the seen value. 
  // if any diff reaches here, it remembers the previous count upto
  // that prefix sum
  diffcountMap.set(prefix[i], countTillDiff + 1)
}

return count;
```

*Kadane's Maximum Subarray Sum*

This is a variation of the prefix sum, where we can discard the
previous running sum, because it no longer contributes to the 
maximum.
While keeping track of the previous maximum

```js
let runningSum = 0, presentMax = arr[0];
let maximumSum = -Math.Infinity

for(let i = 0, i < arr.length; i++) {
  runningSum += arr[i]

  maximumSum = Math.max(maximumSum, runningSum)

  // once the sum goes negative it no longer
  // could contribute to the maximum sum
  runningSum = Math.max(0, runningSum)
}
```

*Trapping rain water*

For trapping rain water, we need a left pillar, a right pillar, and (optionally) a dip. 
In such a case, at a givn position `i` the amount of water trapped would b:

`min(height[leftPillar], height[rightPillar]) - height[i]`.

The catch however, is, the leftPillar doesn't need to be the immediate left. Which is where the prefix max comes in.

```js
let leftMax = heights.reduce((acc, v) => {
  return acc.concat(Math.max(acc.at(-1), v))
}, [heights[0]]).slice(1)

let rightMax = heights.reduceRight((acc, v) => {
  return acc.concat(Math.max(acc.at(-1), v))
}, [heights[0]]).slice(1)


let totalWater = nums.reduce((acc, v, i) => {
  let trapped = Math.min(leftMax[i], rightMax[i]) - v
  return acc + (Math.max(0, trapped))
}, 0)
```

# Interval Problems

The premise is given an array of intervals, we need to check if another interval
would fit in. Or finding an overlap for a given set of intervals.

Two key points:
- check the opposite ends
- if there are too many conditions for overlap, think in terms of negation


```text
Partial Overlaps

[  a-----b  ]
       [ c-----d ]


Partial Overlaps

     [  a-----b  ]
[  c-----d  ]


Matches end to end

[  a-----b  ]
[  c-----d  ]

Inside the lap

[  a--------b  ]
[    c----d    ]
```

Once we have so many conditions, its time to consider `negation`.

```text
What doesn't overlap

Ends before

        [  a-----b  ]
[ c--d ]

Starts After

[  a---b  ]
           [ c---d ]
```

### Finding overlaps

The condition would be:

```python
def has_overlaps(currInterval, newInterval):
  startInclusive = newInterval.start in range(currInterval[0], currInterval[1]+1)
  endInclusive = newInterval.end in range(currInterval[0], currInterval[i]+1)

  return startInclusive or endInclusive
```

```js
const in_range = (point, left, right) => point >= left && point <= right

function hasOverlap(currInterval, newInterval) {
  startInclusive = in_range(newInterval.start, currInterval.start, currInterval.end)
  endInclusice = in_range(newInterval.end, currInterval.start, currInterval.end)

  return startInclusive || endInclusive
}
```

*Check Overlap Possible*

```js
let intervals = [[5, 12], [1, 3], [17, 21]]
let t1 = [14, 16], t2 = [2, 7]

const hasOverlap = (intervals, newInterval) => {
  for(let interval of intervals) {
    if(in_range(newInterval[0], ...interval) || in_range(newInterval[1], ...interval))
      return true
  }

  return false
}
```

*Merge Intervals*

```js
let sortedIntervals = intervals.toSorted((p, n) => p[0] - n[0])

// now that everything is sorted by start times,
// all we need is to traverse the number line
// It would start to look like prefix-xy

let answer = [sortedIntervals[0]]

// To check
// |---| (lastL, lastR)
//      |---|(currL, currR)
// 
// Converting to number line
// | --- | | --- |
// 0     2 3     5
// so lastR < currL : its a New Interval
// otherwise, we want the max of lastR and currR
// because we want to take the max of merge and its not sorted

sortedIntervals.slice(1).reduce((acc, interval) => {
  let [lastL, lastR] = acc.at(-1)
  let [currL, currR] = interval;

  if(lastR < currL) {
    acc.push(interval)
  } else {
    acc.at(-1)[1] = Math.max(lastR, currR)
  }

  return acc;

}, answer)
```

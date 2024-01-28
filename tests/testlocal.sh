#!/bin/bash

echo "Testing gauge"
echo "test.statsd.gauge:333|g" | nc -w 1 -u localhost 8125
echo "test.statsd.gauge:-10|g" | nc -w 1 -u localhost 8125
echo "test.statsd.gauge:+4|g" | nc -w 1 -u localhost 8125
echo "test.statsd.gauge:3.3333|g" | nc -w 1 -u localhost 8125

echo "Testing counters"
echo "test.statsd.counters:2|c|@0.1" | nc -w 1 -u localhost 8125
echo "test.statsd.counters:4|c" | nc -w 1 -u localhost 8125
echo "test.statsd.counters:-4|c" | nc -w 1 -u localhost 8125
echo "test.statsd.counters:1.25|c" | nc -w 1 -u localhost 8125

echo "Testing timers"
echo "test.statsd.timers:320|ms" | nc -w 1 -u localhost 8125
echo "test.statsd.timers:320|ms|@0.1" | nc -w 1 -u localhost 8125
echo "test.statsd.timers:3.7211|ms" | nc -w 1 -u localhost 8125

echo "Testing seq's"
echo "test.statsd.seq.uniques:765|s" | nc -w 1 -u localhost 8125

echo "Testing misc"
echo "a.key.with-0.dash:4|c" | nc -w 1 -u localhost 8125
echo "a.key.with 0.space:4|c" | nc -w 1 -u localhost 8125
echo "a.key.with/0.slash:4|c" | nc -w 1 -u localhost 8125
echo "a.key.with@#*&%$^_0.garbage:4|c" | nc -w 1 -u localhost 8125

echo "Testing multistring"
echo -ne "a.key.with-0.dash:4|c\ngauge:3|g\n" | nc -w 1 -u localhost 8125

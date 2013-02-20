#!/bin/bash
echo "$1 $2 $3"
echo "starting..."
for i in $(seq 1 10); do
  sleep 5
  echo $i
done
echo "done..."

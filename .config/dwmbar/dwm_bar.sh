#!/bin/sh

SEP=" | "

battery_capacity() {
  cat "/sys/class/power_supply/BAT1/capacity"
}

get_battery_status() {
  charge="$(battery_capacity)"
  echo ""$charge"%"
}

get_current_time() {
  echo ""$(date '+%H:%M')""
}

while true
do
  bar=" "
  bar="$bar$(get_battery_status)"
  bar="$bar$SEP$(get_current_time)"
  bar="$bar "

  xsetroot -name "$bar"
  sleep 2
done

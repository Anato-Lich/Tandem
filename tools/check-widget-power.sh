#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

check_dir=$(mktemp -d "${TMPDIR:-/tmp}/tandem-widget-power.XXXXXX")
trap 'rm -rf "$check_dir"' EXIT
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

# Те же общие исходники, что у виджета, без зависимостей от телефона.
# Имя модуля позволяет собрать настоящий WidgetBridge с его import BatteryCore.
swiftc -parse-as-library -module-name BatteryCore \
    -module-cache-path "${TMPDIR:-/tmp}/tandem-widget-check-modules" \
    -target "$(uname -m)-apple-macosx15.0" \
    -o "$check_dir/check" \
    tools/check-widget-power.swift \
    TandemApp/Sources/Tandem/WidgetBridge.swift \
    TandemApp/Sources/TandemWidget/{DevicePresentation,MonitorErrorShim}.swift \
    BatteryCore/Sources/BatteryCore/{Models,TandemSnapshot,ChargeEstimator,Formatting,AirPods,WidgetActivity,PollingPolicy,BatteryPlistParser}.swift
"$check_dir/check"

#!/usr/bin/env bash
set -e

if command -v python3 >/dev/null 2>&1; then
  PY=python3
elif command -v python >/dev/null 2>&1; then
  PY=python
else
  echo "Python not found. Attempting to install..."
  if command -v apt-get >/dev/null 2>&1; then
    sudo apt-get update
    sudo apt-get install -y python3 python3-pip
    PY=python3
  elif command -v dnf >/dev/null 2>&1; then
    sudo dnf install -y python3 python3-pip
    PY=python3
  elif command -v pacman >/dev/null 2>&1; then
    sudo pacman -Sy --noconfirm python python-pip
    PY=python
  else
    echo "No supported package manager found. Please install Python 3 manually."
    exit 1
  fi
fi

$PY -m pip install --upgrade pip
$PY -m pip install requests

$PY "$(cd "$(dirname "$0")" && pwd)/bridge.py"

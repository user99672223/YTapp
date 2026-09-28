#!/bin/bash
# tvd-ctl.sh start|stop|restart — runs tvd.py detached, tracked by a pid file.
PIDF=$HOME/tvtools/tvd.pid
stop() { [ -f $PIDF ] && kill "$(cat $PIDF)" 2>/dev/null; rm -f $PIDF; sleep 1; }
start() { mkdir -p $HOME/tvtools && cd $HOME/tvtools && setsid nohup ${PMD3_PYTHON:-$HOME/.local/share/pipx/venvs/pymobiledevice3/bin/python} $(dirname "$(readlink -f "$0")")/tvd.py >> $HOME/tvtools/tvd.out 2>&1 < /dev/null & echo $! > $PIDF; }
case "$1" in start) start;; stop) stop;; restart) stop; start;; esac

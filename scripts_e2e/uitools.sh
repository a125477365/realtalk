#!/bin/bash
# RealTalk iOS 模拟器 UI 自动化辅助
export PATH="$HOME/Library/Python/3.9/bin:$PATH"
D=DE35A90A-50B0-46AC-9D5D-CDC4EA121413
BID=com.tanjian.realtalk
SHOTS_DIR=/Users/tanjian/Documents/codes/realtalk/e2e_screenshots/round2

PY='
import json,sys,subprocess
raw=subprocess.run(["idb","ui","describe-all","--udid","DE35A90A-50B0-46AC-9D5D-CDC4EA121413"],capture_output=True,text=True).stdout
try: els=json.loads(raw)
except Exception:
    print("PARSE_FAIL", raw[:200]); sys.exit(1)
def flat(e):
    yield e
    for c in e.get("children") or []:
        yield from flat(c)
out=[]
def walk(e):
    out.append(e)
for e in els:
    for it in flat(e):
        f=it.get("frame") or {}
        lab=it.get("AXLabel") or ""
        val=it.get("AXValue") or ""
        if isinstance(val,str) and len(val)>60: val=val[:60]+"..."
        typ=it.get("type","")
        en="" if it.get("enabled",True) else " [DISABLED]"
        if lab or val or typ in ("Button","TextField","Cell","Switch","StaticText","Image","SecureTextField"):
            out.append((typ,lab,val,f,en))
import os
if os.environ.get("RT_MODE")=="tap":
    pat=os.environ.get("RT_PAT","")
    for typ,lab,val,f,en in out:
        if pat in lab or (isinstance(val,str) and pat in val):
            print("%.0f %.0f" % (f["x"]+f["width"]/2, f["y"]+f["height"]/2)); sys.exit(0)
    sys.exit(2)
for typ,lab,val,f,en in out:
    print("%s|%s|%s|%.0f,%.0f,%.0f,%.0f%s" % (typ,lab,val,f["x"],f["y"],f["width"],f["height"],en))
'

tree() { python3 -c "$PY"; }

taplabel() { # 按 AXLabel/值 子串点击元素中心
  local pat="$1"
  local coord=$(RT_MODE=tap RT_PAT="$pat" python3 -c "$PY")
  if [ -z "$coord" ]; then echo "NOT FOUND: $pat"; return 1; fi
  echo "TAP ($coord) <- $pat"
  idb ui tap $coord --udid $D
  sleep 1.2
}

tapxy() { echo "TAP $1 $2"; idb ui tap "$1" "$2" --udid $D; sleep 1; }
swipe_up() { idb ui swipe 200 650 200 250 --udid $D; sleep 1; }
swipe_down() { idb ui swipe 200 250 200 650 --udid $D; sleep 1; }
type_text() { idb ui text "$1" --udid $D; sleep 0.5; }

shot() { xcrun simctl io $D screenshot "$SHOTS_DIR/$1.png" >/dev/null 2>&1 && echo "SHOT $1"; }

relaunch() { # relaunch [extra app args...]
  xcrun simctl terminate $D $BID 2>/dev/null
  sleep 1
  xcrun simctl launch $D $BID "$@"
  sleep 4
}

"$@"

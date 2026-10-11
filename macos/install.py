import getpass
import json
import os
import plistlib
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LABEL = 'local.bitsrun.auto'
APP = Path.home() / 'Library/Application Support/bitsrun'
PLIST = Path.home() / f'Library/LaunchAgents/{LABEL}.plist'
CONFIG = Path.home() / '.config/bitsrun/bit-user.json'


def run(*args, **kwargs):
  return subprocess.run(args, check=True, **kwargs)


def main():
  if sys.platform != 'darwin':
    raise SystemExit('仅支持 macOS')
  if '--uninstall' in sys.argv:
    subprocess.run(['/bin/launchctl', 'bootout', f'gui/{os.getuid()}', str(PLIST)],
                   check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    PLIST.unlink(missing_ok=True)
    shutil.rmtree(APP, ignore_errors=True)
    print('服务已卸载，凭据保留在', CONFIG)
    return
  uv = shutil.which('uv')
  if not uv:
    raise SystemExit('需要 uv')
  # Build everything before changing a running installation.
  run('swiftc', '-O', str(ROOT / 'macos/Watcher.swift'), '-o', str(ROOT / 'macos/watcher'))
  username = input('校园网账号: ').strip()
  password = getpass.getpass('校园网密码: ')
  interface = input('有线网卡设备名（回车自动识别）: ').strip()
  if not username or not password:
    raise SystemExit('账号密码不能为空')
  subprocess.run(['/bin/launchctl', 'bootout', f'gui/{os.getuid()}', str(PLIST)],
                 check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
  APP.mkdir(parents=True, exist_ok=True)
  shutil.copy2(ROOT / 'macos/watcher', APP / 'watcher')
  # Install a non-editable package; the checkout can be moved or removed later.
  run(uv, 'venv', str(APP / 'venv'), '--python', '3.11')
  run(uv, 'pip', 'install', '--python', str(APP / 'venv/bin/python'), str(ROOT))
  CONFIG.parent.mkdir(parents=True, exist_ok=True)
  fd = os.open(CONFIG, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
  os.fchmod(fd, 0o600)
  with os.fdopen(fd, 'w') as file:
    json.dump({'username': username, 'password': password, 'interface': interface}, file)
  logs = Path.home() / 'Library/Logs/bitsrun'
  logs.mkdir(parents=True, exist_ok=True)
  PLIST.parent.mkdir(parents=True, exist_ok=True)
  PLIST.write_bytes(plistlib.dumps({
    'Label': LABEL,
    'ProgramArguments': [str(APP / 'watcher'), str(APP / 'venv/bin/bitsrun-auto')],
    'RunAtLoad': True, 'KeepAlive': True, 'ThrottleInterval': 15,
    'StandardOutPath': str(logs / 'auto.log'),
    'StandardErrorPath': str(logs / 'auto.log'),
  }))
  run('/bin/launchctl', 'bootstrap', f'gui/{os.getuid()}', str(PLIST))
  print('已启用事件驱动自动登录')


if __name__ == '__main__':
  main()

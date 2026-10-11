import hmac
import ipaddress
import json
import re
import subprocess
import sys
from hashlib import sha1
from pathlib import Path

import httpx

from bitsrun.utils import fkbase64, xencode

BASE = 'http://10.0.0.55'
CONFIG = Path.home() / '.config/bitsrun/bit-user.json'


def command(*args):
  return subprocess.check_output(args, text=True, timeout=5)


def ethernet_devices(text):
  devices = set()
  for block in text.split('\n\n'):
    port = re.search(r'Hardware Port: (.+)', block)
    device = re.search(r'Device: (\S+)', block)
    if port and device and re.search(r'ethernet|\blan\b', port[1], re.IGNORECASE):
      devices.add(device[1])
  return devices


def route_interface(text):
  match = re.search(r'^\s*interface:\s*(\S+)', text, re.MULTILINE)
  return match[1] if match else None


def eligible_interface(config):
  devices = ethernet_devices(command('/usr/sbin/networksetup', '-listallhardwareports'))
  try:
    interface = route_interface(command('/sbin/route', '-n', 'get', '10.0.0.55'))
  except subprocess.CalledProcessError:
    return None
  if interface not in devices:
    return None
  if config.get('interface') and config['interface'] != interface:
    return None
  return interface


def jsonp(response):
  response.raise_for_status()
  text = response.text.strip()
  if not text.startswith('jsonp(') or not text.rstrip(';').endswith(')'):
    raise ValueError('Invalid portal response')
  data = json.loads(text.rstrip(';')[6:-1])
  if not isinstance(data, dict):
    raise TypeError('Invalid portal data')
  return data


def login_params(username, password, ip, token, acid='43'):
  digest = hmac.new(token.encode(), b'', 'MD5').hexdigest()
  data = {'username': username, 'password': password, 'acid': acid,
          'ip': ip, 'enc_ver': 'srun_bx1'}
  info = '{SRBX1}' + fkbase64(xencode(json.dumps(data, separators=(',', ':')), token))
  checksum = sha1(''.join(token + str(value) for value in
                         [username, digest, acid, ip, 200, 1, info]).encode()).hexdigest()
  return {'callback': 'jsonp', 'action': 'login', 'username': username,
          'password': '{MD5}' + digest, 'ac_id': acid, 'ip': ip,
          'type': 1, 'n': 200, 'info': info, 'chksum': checksum}


def attempt(config):
  interface = eligible_interface(config)
  if not interface:
    return 0
  local_ip = command('/usr/sbin/ipconfig', 'getifaddr', interface).strip()
  ipaddress.IPv4Address(local_ip)
  transport = httpx.HTTPTransport(local_address=local_ip, retries=0)
  with httpx.Client(base_url=BASE, transport=transport, timeout=5,
                   trust_env=False, follow_redirects=False) as client:
    page = client.get('/srun_portal_pc', params={'ac_id': '43', 'theme': 'bit'})
    page.raise_for_status()
    if 'srun' not in page.text.lower() or not any(
        marker in page.text for marker in ['北京理工大学', 'BEIJING INSTITUTE', 'www.bit.edu.cn']):
      return 0
    status = jsonp(client.get('/cgi-bin/rad_user_info', params={'callback': 'jsonp'}))
    if status.get('user_name'):
      return 0
    ip = status.get('online_ip')
    if ip != local_ip:
      raise ValueError('Portal IP differs from Ethernet IP')
    challenge = jsonp(client.get('/cgi-bin/get_challenge', params={
      'callback': 'jsonp', 'username': config['username'], 'ip': ip}))
    # Recheck the route before sending credentials after a network transition.
    if eligible_interface(config) != interface:
      return 0
    params = login_params(config['username'], config['password'], ip, challenge['challenge'])
    result = jsonp(client.get('/cgi-bin/srun_portal', params=params))
    if result.get('error') != 'ok':
      # Never print response bodies or request URLs containing credentials.
      print('校园网认证失败，请检查账号或认证服务', file=sys.stderr)
      return 2
    status = jsonp(client.get('/cgi-bin/rad_user_info', params={'callback': 'jsonp'}))
    if status.get('user_name') != config['username']:
      raise ValueError('Login verification failed')
    print('校园网登录成功', flush=True)
    return 0


def main():
  try:
    if CONFIG.stat().st_mode & 0o077:
      print('凭据文件权限必须为 600', file=sys.stderr)
      return 2
    config = json.loads(CONFIG.read_text())
    if not all(isinstance(config.get(k), str) and config[k] for k in ['username', 'password']):
      return 2
    return attempt(config)
  except (FileNotFoundError, json.JSONDecodeError):
    print('请先运行安装脚本配置凭据', file=sys.stderr)
    return 2
  except (httpx.HTTPError, OSError, subprocess.SubprocessError, ValueError, KeyError, TypeError):
    print('网络或认证服务暂不可用', file=sys.stderr)
    return 1


if __name__ == '__main__':
  sys.exit(main())

import json
import subprocess
from unittest.mock import Mock

import httpx
import pytest

from bitsrun import auto

CONFIG = {'username': 'student', 'password': 'secret'}
IP = '10.1.2.3'


def install_network(monkeypatch, interface='en5'):
  def command(*args):
    if 'networksetup' in args[0]:
      return 'Hardware Port: Wi-Fi\nDevice: en0\n\nHardware Port: USB Ethernet\nDevice: en5\n'
    if 'route' in args[0]:
      return f' interface: {interface}\n'
    return IP
  monkeypatch.setattr(auto, 'command', command)


def portal(monkeypatch, handler):
  original = httpx.Client
  monkeypatch.setattr(auto.httpx, 'Client', lambda **kwargs: original(
    base_url=auto.BASE, transport=httpx.MockTransport(handler), follow_redirects=False))


def response(data):
  return httpx.Response(200, text='jsonp(' + json.dumps(data) + ')')


def test_wifi_never_contacts_portal(monkeypatch):
  install_network(monkeypatch, 'en0')
  client = Mock(side_effect=AssertionError('must not make an HTTP request'))
  monkeypatch.setattr(auto.httpx, 'Client', client)
  assert auto.attempt(CONFIG) == 0
  client.assert_not_called()


def test_wrong_page_never_sends_credentials(monkeypatch):
  install_network(monkeypatch)
  requests = []
  def handler(request):
    requests.append(request)
    return httpx.Response(200, text='Another private network')
  portal(monkeypatch, handler)
  assert auto.attempt(CONFIG) == 0
  assert len(requests) == 1


def test_existing_session_is_left_alone(monkeypatch):
  install_network(monkeypatch)
  def handler(request):
    if request.url.path == '/srun_portal_pc':
      return httpx.Response(200, text='北京理工大学 srun')
    assert request.url.path == '/cgi-bin/rad_user_info'
    return response({'online_ip': IP, 'user_name': 'another-user'})
  portal(monkeypatch, handler)
  assert auto.attempt(CONFIG) == 0


def test_complete_login_and_verification(monkeypatch):
  install_network(monkeypatch)
  logged_in = False
  def handler(request):
    nonlocal logged_in
    path = request.url.path
    if path == '/srun_portal_pc':
      return httpx.Response(200, text='北京理工大学 srun')
    if path == '/cgi-bin/rad_user_info':
      return response({'online_ip': IP, 'user_name': 'student' if logged_in else None})
    if path == '/cgi-bin/get_challenge':
      return response({'challenge': '0123456789abcdef'})
    assert path == '/cgi-bin/srun_portal'
    params = request.url.params
    assert params['ac_id'] == '43'
    assert params['ip'] == IP
    assert params['password'].startswith('{MD5}')
    assert params['info'].startswith('{SRBX1}')
    assert 'secret' not in str(request.url)
    logged_in = True
    return response({'error': 'ok'})
  portal(monkeypatch, handler)
  assert auto.attempt(CONFIG) == 0
  assert logged_in


def test_route_change_aborts_login(monkeypatch):
  install_network(monkeypatch)
  def handler(request):
    if request.url.path == '/srun_portal_pc':
      return httpx.Response(200, text='北京理工大学 srun')
    if request.url.path == '/cgi-bin/rad_user_info':
      return response({'online_ip': IP})
    assert request.url.path == '/cgi-bin/get_challenge'
    monkeypatch.setattr(auto, 'eligible_interface', lambda _: None)
    return response({'challenge': '0123456789abcdef'})
  portal(monkeypatch, handler)
  assert auto.attempt(CONFIG) == 0


def test_disconnected_is_quiet(monkeypatch):
  def command(*args):
    if 'networksetup' in args[0]:
      return 'Hardware Port: USB Ethernet\nDevice: en5\n'
    raise subprocess.CalledProcessError(1, args)
  monkeypatch.setattr(auto, 'command', command)
  assert auto.eligible_interface(CONFIG) is None


def test_jsonp_rejects_html():
  with pytest.raises(ValueError):
    auto.jsonp(httpx.Response(200, text='<html>login</html>',
                             request=httpx.Request('GET', auto.BASE)))

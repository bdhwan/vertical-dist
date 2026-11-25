#!/usr/bin/env python3
"""manifest v2 확인기 — 표준 라이브러리만(Pi·맥 공용).

manifest 서명은 없다(사용자 결정). 여기서 보는 것:
  - 형식: schema 2, version, server/apps 항목, 파일 이름(경로 이동 차단), sha256(소문자 hex 64), size
  - --dir 를 주면 그 폴더의 실제 파일 크기·sha256 (깨짐·덜 받음 검사용, 인증 아님)
  - appVariants[](같은 앱의 다른 ABI APK, 예: 32비트 탭용 armeabi-v7a 뷰어) — apps[] 와 같은 형식 + abis.
    apps[] 에 같은 package 를 두 번 넣지 않는 이유: 이 파일의 옛 판이 "package 중복"으로 거부하고, 옛 뷰어는
    apps[] 를 전부 받으며(allFiles) 첫 항목만 고른다. 옛 판·옛 뷰어·송출 앱·Pi update.sh 는 appVariants 를 모르고 지나간다.
    "abis" 가 없으면 arm64-v8a 로 본다. "abis": [] 는 ABI 상관없음.

사용
  ota_verify.py manifest.json                       형식만
  ota_verify.py manifest.json --dir DIR             + DIR 안의 server·apps 파일 전부
  ota_verify.py manifest.json --dir DIR --only server        server tar 만(Pi)
  ota_verify.py manifest.json --dir DIR --only com.vertical.publisher
  ota_verify.py manifest.json --get server.file     값 하나 출력(셸에서 쓰기)  예) apps.com.sec.vertical_pad.versionCode

종료 코드: 0 맞음, 1 틀림, 2 사용법·읽기 오류
"""
import argparse
import hashlib
import json
import os
import re
import sys

SAFE_FILE = re.compile(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$')
SHA256 = re.compile(r'^[0-9a-f]{64}$')


class Bad(Exception):
    pass


def _file_entry(e, where):
    if not isinstance(e, dict):
        raise Bad('%s: 객체가 아님' % where)
    f = e.get('file')
    if not isinstance(f, str) or not SAFE_FILE.match(f):
        raise Bad('%s: 허용되지 않는 파일 이름 %r' % (where, f))
    if not isinstance(e.get('sha256'), str) or not SHA256.match(e['sha256']):
        raise Bad('%s: sha256 형식이 틀림' % where)
    if not isinstance(e.get('size'), int) or isinstance(e.get('size'), bool) or e['size'] <= 0:
        raise Bad('%s: size 가 양의 정수가 아님' % where)


def _abis(a, where):
    ab = a.get('abis')
    if ab is None:
        return ('arm64-v8a',)
    if not isinstance(ab, list) or not all(isinstance(x, str) and x for x in ab):
        raise Bad('%s: abis 가 문자열 배열이 아님' % where)
    return tuple(ab)


def _app_entry(a, where):
    _file_entry(a, where)
    if not isinstance(a.get('package'), str) or not a['package']:
        raise Bad('%s: package 없음' % where)
    vc = a.get('versionCode')
    if not isinstance(vc, int) or isinstance(vc, bool) or vc <= 0:
        raise Bad('%s: versionCode 가 양의 정수가 아님' % where)
    return _abis(a, where)


def validate(m):
    if not isinstance(m, dict):
        raise Bad('manifest 가 객체가 아님')
    if m.get('schema') != 2:
        raise Bad('schema %r — v2 가 아님' % m.get('schema'))
    if not isinstance(m.get('version'), str) or not m['version']:
        raise Bad('version 없음')
    if m.get('server') is not None:
        _file_entry(m['server'], 'server')
    apps = m.get('apps') or []
    if not isinstance(apps, list):
        raise Bad('apps 가 배열이 아님')
    seen = set()
    pairs = set()
    for i, a in enumerate(apps):
        where = 'apps[%d]' % i
        abis = _app_entry(a, where)
        if a['package'] in seen:
            raise Bad('%s: package 중복 %s' % (where, a['package']))
        seen.add(a['package'])
        pairs.update((a['package'], x) for x in abis)
    variants = m.get('appVariants') or []
    if not isinstance(variants, list):
        raise Bad('appVariants 가 배열이 아님')
    for i, a in enumerate(variants):
        where = 'appVariants[%d]' % i
        abis = _app_entry(a, where)
        if a['package'] not in seen:
            raise Bad('%s: apps[] 에 없는 package %s (기본 APK 가 먼저 있어야 함)' % (where, a['package']))
        if not abis:
            raise Bad('%s: abis 가 비어 있음(ABI 상관없는 APK 는 apps[] 에)' % where)
        for x in abis:
            if (a['package'], x) in pairs:
                raise Bad('%s: %s %s 가 이미 있음' % (where, a['package'], x))
            pairs.add((a['package'], x))
    names = [e['file'] for e in entries(m, None)]
    if len(names) != len(set(names)):
        raise Bad('파일 이름 중복')


def entries(m, only):
    """(server + apps) 중 only(None|'server'|package) 에 해당하는 항목"""
    out = []
    if m.get('server') is not None and only in (None, 'server'):
        out.append(m['server'])
    for a in (m.get('apps') or []) + (m.get('appVariants') or []):
        if only is None or only == a.get('package'):
            out.append(a)
    return out


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for b in iter(lambda: f.read(1 << 20), b''):
            h.update(b)
    return h.hexdigest()


def check_files(m, d, only):
    es = entries(m, only)
    if not es:
        raise Bad('확인할 항목 없음 (--only %s)' % only)
    for e in es:
        p = os.path.join(d, e['file'])
        if not os.path.isfile(p):
            raise Bad('%s 없음' % e['file'])
        size = os.path.getsize(p)
        if size != e['size']:
            raise Bad('%s 크기 %d (기대 %d)' % (e['file'], size, e['size']))
        if sha256_file(p) != e['sha256']:
            raise Bad('%s sha256 불일치' % e['file'])
        print('  ok %s (%d B)' % (e['file'], size))


def get(m, path):
    """server.file / version / apps.<package>.versionCode / ios.build"""
    parts = path.split('.')
    if parts[0] == 'apps' and len(parts) >= 3:
        # package 이름에 점이 있으므로 마지막 마디가 필드
        pkg, field = '.'.join(parts[1:-1]), parts[-1]
        for a in m.get('apps') or []:
            if a.get('package') == pkg:
                return a.get(field)
        return None
    cur = m
    for p in parts:
        if not isinstance(cur, dict):
            return None
        cur = cur.get(p)
    return cur


def main():
    ap = argparse.ArgumentParser(description='manifest v2 확인(형식 + 파일 sha256·size)')
    ap.add_argument('manifest')
    ap.add_argument('--dir', help='파일이 든 폴더 — 크기·sha256 확인')
    ap.add_argument('--only', help="'server' 또는 package 이름 — 그 항목만 확인")
    ap.add_argument('--get', help='값 하나 출력 (예: server.file, apps.com.vertical.publisher.versionCode)')
    a = ap.parse_args()
    try:
        with open(a.manifest, 'rb') as f:
            m = json.loads(f.read().decode('utf-8'))
    except (OSError, ValueError) as e:
        print('manifest 읽기 실패: %s' % e, file=sys.stderr)
        return 2
    try:
        validate(m)
        if a.get:
            v = get(m, a.get)
            if v is None:
                print('%s 없음' % a.get, file=sys.stderr)
                return 1
            print(v if not isinstance(v, (dict, list)) else json.dumps(v))
            return 0
        if a.dir:
            check_files(m, a.dir, a.only)
    except Bad as e:
        print('✗ %s' % e, file=sys.stderr)
        return 1
    except OSError as e:
        print('파일 읽기 실패: %s' % e, file=sys.stderr)
        return 2
    print('✓ manifest %s 확인%s' % (m['version'], '' if a.dir else '(형식만)'))
    return 0


if __name__ == '__main__':
    sys.exit(main())

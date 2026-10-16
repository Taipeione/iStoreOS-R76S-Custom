#!/usr/bin/env python3
"""Audit downloadable artifacts and gzip/raw identity, independently of staging trees."""
from pathlib import Path
import argparse,hashlib,json,subprocess,zlib

PUBLISHED_METADATA = {
    'ota.json', 'ota.json.sig', 'ota-public.pem', 'version.latest',
    'version.index', 'ota.footer.html', 'BOOTLOADER_INFO.txt',
    'RELEASE-NOTES.md', 'TEST-REPORT.txt', 'r76s-ota-preserve-state',
    'BUILD-VALIDATION.txt', 'sources.lock.json', 'release.json',
    'R76S-V1.4.6-PLUGIN-MATRIX.md',
}

def published_files(root):
    """Return only files uploaded by the workflow, excluding internal build state."""
    return sorted(
        p for p in root.iterdir()
        if p.is_file() and p.name not in ('sha256', 'sha256sums')
        and (p.suffix in ('.img', '.bin', '.gz') or p.name in PUBLISHED_METADATA)
    )

def sha(path):
    h=hashlib.sha256()
    with path.open('rb') as source:
        for block in iter(lambda:source.read(1024*1024),b''): h.update(block)
    return h.hexdigest()

def audit(root):
    root=Path(root)
    manifest=json.loads((root/'ota.json').read_text())
    assert manifest['version']=='R76S-V1.4.6'
    assert manifest['target']=='rockchip/armv8'
    assert manifest['supported_devices']==['friendlyarm,nanopi-r76s']
    assert manifest['hardware_validation']=='not_performed'
    image=root/manifest['image']
    assert image.name=='R76S-V1.4.6-TF-squashfs.img.gz'
    assert manifest['size']==image.stat().st_size and manifest['sha256']==sha(image)
    assert manifest['url'].endswith('/R76S-V1.4.6/'+image.name)
    for item in manifest['artifacts']:
        assert Path(item['name']).name==item['name']
        p=root/item['name']
        assert p.stat().st_size==item['size'] and sha(p)==item['sha256']
    assert (root/'version.index').read_text().strip()=='24.10.8-R76S-V1.4.6'
    latest=(root/'version.latest').read_text()
    assert '[24.10.8-R76S-V1.4.6]('+image.name+')' in latest
    assert 'SHA256: '+manifest['sha256'] in latest
    decoder=zlib.decompressobj(16+zlib.MAX_WBITS)
    total=0
    with image.open('rb') as compressed,(root/image.name[:-3]).open('rb') as raw:
        for block in iter(lambda:compressed.read(65536),b''):
            payload=decoder.decompress(block)
            assert raw.read(len(payload))==payload,'gzip/raw mismatch'
            total+=len(payload)
        assert decoder.eof and total>16*1024*1024,'invalid/truncated disk image'
        assert raw.read()==b'','raw artifact contains metadata trailer'
    assert subprocess.run(['openssl','pkeyutl','-verify','-pubin','-inkey',str(root/'ota-public.pem'),
        '-rawin','-in',str(root/'ota.json'),'-sigfile',str(root/'ota.json.sig')],capture_output=True).returncode==0,'OTA signature invalid'
    print('RELEASE_IMAGE_MANIFEST_SIGNATURE=PASS')

if __name__=='__main__':
    parser=argparse.ArgumentParser()
    parser.add_argument('root',type=Path)
    parser.add_argument('--finalize',action='store_true')
    args=parser.parse_args()
    audit(args.root)
    if args.finalize:
        files=published_files(args.root)
        if not files:
            raise SystemExit('no published release assets found')
        sums=''.join(f'{sha(p)}  {p.name}\n' for p in files)
        for name in ('sha256','sha256sums'): (args.root/name).write_text(sums)

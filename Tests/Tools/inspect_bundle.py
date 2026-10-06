import json
import pathlib
import re
import subprocess
import sys


def output(*arguments):
    return subprocess.check_output(arguments, text=True)


results = []
for argument in sys.argv[1:]:
    bundle = pathlib.Path(argument).resolve()
    executable = bundle / 'Contents/MacOS/Notational Velocity'
    architecture = output('/usr/bin/lipo', '-archs', str(executable)).strip()
    assert architecture == 'arm64', architecture
    commands = output('/usr/bin/otool', '-l', str(executable))
    minimum = re.search(r'^\s+minos (\S+)$', commands, re.MULTILINE)
    assert minimum and minimum[1] == '15.0', 'Unexpected minimum OS'
    dependencies = [line.strip().split(' (')[0] for line in
                    output('/usr/bin/otool', '-L', str(executable)).splitlines()[1:]]
    assert all(path.startswith(('/System/Library/', '/usr/lib/')) for path in dependencies), dependencies
    imports = output('/usr/bin/nm', '-u', str(executable))
    forbidden = r'^\s*_(?:EVP_|BIO_|OPENSSL_|AES_|MD5(?:_|$)|SHA1(?:_|$)|idea_|CGS[A-Z])'
    assert not re.search(forbidden, imports, re.MULTILINE), 'Retired/private symbol import'
    files = [str(path.relative_to(bundle)) for path in bundle.rglob('*')]
    assert not any(any(token in path for token in
                       ('Sparkle', 'AutoHyperlinks', 'isolated-launch')) for path in files)
    results.append(dict(bundle=str(bundle), architecture=architecture,
                        minimumOS=minimum[1], dependencies=dependencies,
                        forbiddenImports=False, retiredBundledFrameworks=False))
assert results, 'Provide one or more app bundles'
print(json.dumps(results, indent=2))

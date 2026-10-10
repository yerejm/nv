import json
import pathlib
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[2]


def application_project():
    return json.loads(subprocess.check_output([
        '/usr/bin/plutil', '-convert', 'json', '-o', '-',
        str(ROOT / 'Notation.xcodeproj/project.pbxproj')]))


def header_search_paths():
    objects = application_project()['objects']
    settings = next(obj['buildSettings'] for obj in objects.values()
                    if obj.get('isa') == 'XCBuildConfiguration'
                    and obj.get('name') == 'Development'
                    and 'HEADER_SEARCH_PATHS' in obj['buildSettings'])
    return [path.replace('$(SRCROOT)', '$(SRCROOT)/..')
            for path in settings['HEADER_SEARCH_PATHS']] + ['$(SRCROOT)/Support']


def compiler_flags():
    objects = application_project()['objects']
    flags = {}
    for obj in objects.values():
        if obj.get('isa') == 'PBXBuildFile' and 'COMPILER_FLAGS' in obj.get('settings', {}):
            flags[objects[obj['fileRef']]['path'].split('/')[-1]] = obj['settings']['COMPILER_FLAGS']
    return flags


def automatic_reference_counting():
    objects = application_project()['objects']
    settings = next(obj['buildSettings'] for obj in objects.values()
                    if obj.get('isa') == 'XCBuildConfiguration' and obj.get('name') == 'Development'
                    and obj['buildSettings'].get('INFOPLIST_FILE') == 'Configuration/Info.plist')
    project = next(obj['buildSettings'] for obj in objects.values()
                   if obj.get('isa') == 'XCBuildConfiguration' and obj.get('name') == 'Development'
                   and obj is not settings and 'INFOPLIST_FILE' not in obj['buildSettings'])
    return {key: settings.get(key, project.get(key, 'NO'))
            for key in ['CLANG_ENABLE_OBJC_ARC', 'CLANG_ENABLE_OBJC_WEAK']}


def file_groups(add, filenames):
    root_children = []
    group = add(dict(isa='PBXGroup', children=root_children, sourceTree='<group>'))
    groups = {'': group}
    children = {group: root_children}

    def directory(path):
        name = str(path) if str(path) != '.' else ''
        if name not in groups:
            parent = directory(path.parent)
            value = dict(isa='PBXGroup', children=[], sourceTree='<group>')
            if len(path.parts) == 1:
                value.update(name=path.name, path='.' if path.name == 'Tests' else '../' + path.name)
            else:
                value['path'] = path.name
            key = add(value)
            groups[name] = key
            children[key] = value['children']
            children[parent].append(key)
        return groups[name]

    refs = []
    for filename in filenames:
        path = pathlib.PurePosixPath(filename)
        parent = directory(path.parent)
        ref = add(dict(isa='PBXFileReference', path=path.name, sourceTree='<group>',
                       lastKnownFileType='sourcecode.c.h' if path.suffix == '.h' else
                       'sourcecode.c.objc' if path.suffix == '.m' else 'sourcecode.c.c'))
        children[parent].append(ref)
        refs.append(ref)
    return group, children[group], refs


if __name__ == '__main__':
    for path in header_search_paths():
        if path != '$(inherited)':
            print(path.replace('$(SRCROOT)', str(ROOT / 'Tests')))

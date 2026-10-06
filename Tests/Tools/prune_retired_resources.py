import pathlib
import plistlib

ROOT = pathlib.Path(__file__).resolve().parents[2]
LABELS = {'sparkleUpdateItem', 'syncWaitPanel', 'syncWaitSpinner', 'syncWaitQuit:',
          'syncAccountField', 'syncPasswordField', 'enabledSyncButton', 'verifyStatusImageView',
          'verifyStatusField', 'syncingFrequency', 'syncEncAlertView', 'syncEncAlertField',
          'toggledSyncing:', 'syncFrequencyChange:', 'visitSimplenoteSite:'}
OWNED = {'NSSubviews', 'NSCell', 'NSCells', 'NSWindowView', 'NSView', 'NSContentView'}


def references(value):
    if isinstance(value, plistlib.UID):
        yield value.data
    elif isinstance(value, list):
        for element in value:
            yield from references(element)
    elif isinstance(value, dict):
        for element in value.values():
            yield from references(element)


def prune(filename):
    archive = plistlib.loads(filename.read_bytes())
    objects = archive['$objects']

    def value(reference):
        return objects[reference.data] if isinstance(reference, plistlib.UID) else reference

    def children(index):
        result = {index}
        obj = objects[index]
        if isinstance(obj, dict):
            for key, entry in obj.items():
                if key in OWNED or key == 'NS.objects':
                    for child in references(entry):
                        result.update(children(child))
        return result

    connections = {index for index, obj in enumerate(objects) if isinstance(obj, dict)
                   and isinstance(value(obj.get('NSLabel')), str) and value(obj.get('NSLabel')) in LABELS}
    seeds = {objects[index]['NSDestination'].data for index in connections
             if not value(objects[index]['NSLabel']).endswith(':')}
    removed = set(connections)
    for seed in seeds:
        removed.update(children(seed))
    for index, obj in enumerate(objects):
        if isinstance(obj, dict) and 'NSTabView' in obj and 'NSView' in obj:
            if children(obj['NSView'].data) & seeds:
                removed.update(children(index))
    for obj in objects:
        if not isinstance(obj, dict) or 'NSTabViewItems' not in obj:
            continue
        items = value(obj['NSTabViewItems'])['NS.objects']
        retained = [item for item in items if item.data not in removed]
        assert retained
        value(obj['NSTabViewItems'])['NS.objects'] = retained
        if obj.get('NSSelectedTabViewItem', plistlib.UID(0)).data in removed:
            obj['NSSelectedTabViewItem'] = retained[0]
            value(obj.get('NSSubviews'))['NS.objects'] = [objects[retained[0].data]['NSView']]
    for index, obj in enumerate(objects):
        if isinstance(obj, dict) and ('NSSource' in obj or 'NSDestination' in obj):
            if any(ref in removed for key in ['NSSource', 'NSDestination'] for ref in references(obj.get(key))):
                removed.add(index)
    objectdata = objects[archive['$top']['IB.objectdata'].data]
    for key, val in list(objectdata.items()):
        if key.endswith('Keys') and key[:-4] + 'Values' in objectdata:
            keys = value(val).get('NS.objects', [])
            values = value(objectdata[key[:-4] + 'Values']).get('NS.objects', [])
            assert len(keys) == len(values)
            pairs = [(k, v) for k, v in zip(keys, values)
                     if not any(ref in removed for ref in references([k, v]))]
            value(val)['NS.objects'] = [k for k, _ in pairs]
            value(objectdata[key[:-4] + 'Values'])['NS.objects'] = [v for _, v in pairs]

    def clean(value):
        if isinstance(value, plistlib.UID):
            return plistlib.UID(0) if value.data in removed else value
        if isinstance(value, list):
            return [clean(entry) for entry in value
                    if not isinstance(entry, plistlib.UID) or entry.data not in removed]
        if isinstance(value, dict):
            return {key: clean(entry) for key, entry in value.items()}
        return value

    objects = [clean(obj) for obj in objects]
    reachable = {0}
    pending = list(references(archive['$top']))
    while pending:
        index = pending.pop()
        if index not in reachable:
            reachable.add(index)
            pending.extend(references(objects[index]))
    ordered = sorted(reachable)
    remapping = {old: new for new, old in enumerate(ordered)}

    def remap(value):
        if isinstance(value, plistlib.UID):
            return plistlib.UID(remapping[value.data])
        if isinstance(value, list):
            return [remap(entry) for entry in value]
        if isinstance(value, dict):
            return {key: remap(entry) for key, entry in value.items()}
        return value

    archive['$objects'] = [remap(objects[index]) for index in ordered]
    archive['$top'] = remap(archive['$top'])
    filename.write_bytes(plistlib.dumps(archive, fmt=plistlib.FMT_BINARY, sort_keys=False))
    print(filename.relative_to(ROOT), len(removed), 'retired objects removed')


if __name__ == '__main__':
    for localization in ['en', 'de', 'it', 'fr', 'pt', 'zh_CN']:
        for name in ['MainMenu', 'NotationPrefsView']:
            prune(ROOT / f'{localization}.lproj/{name}.nib/keyedobjects.nib')

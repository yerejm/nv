import copy
import pathlib
import xml.etree.ElementTree as ET

from prune_retired_resources import LABELS, OWNED, ROOT


def prune(filename, controls):
    tree = ET.parse(filename)
    root = tree.getroot()
    definitions = {element.get('id'): copy.deepcopy(element) for element in root.iter() if element.get('id')}
    nodes = {element.get('id'): element for element in root.iter() if element.get('id')}

    def target(element):
        return element.get('ref') or element.get('id')

    def owned(identifier, visited=None):
        visited = set() if visited is None else visited
        if identifier in visited:
            return set()
        visited.add(identifier)
        result = {identifier}
        element = nodes.get(identifier)
        if element is not None:
            for child in element:
                if child.get('key') in OWNED:
                    if child.tag == 'reference':
                        result.update(owned(target(child), visited))
                    elif child.get('class') in ['NSArray', 'NSMutableArray']:
                        for subview in child:
                            if target(subview):
                                result.update(owned(target(subview), visited))
                    elif target(child):
                        result.update(owned(target(child), visited))
        return result

    removed = set()
    if controls:
        for connection in root.iter('object'):
            if connection.get('class') not in ['IBOutletConnection', 'IBActionConnection']:
                continue
            label = connection.find('./string[@key="label"]')
            if label is not None and label.text in LABELS and not label.text.endswith(':'):
                destination = connection.find('./reference[@key="destination"]')
                if destination is not None:
                    removed.update(owned(destination.get('ref')))
        for item in root.iter('object'):
            if item.get('class') == 'NSTabViewItem':
                view = next((child for child in item if child.get('key') == 'NSView'), None)
                if view is not None and owned(target(view)) & removed:
                    removed.update(owned(item.get('id')))

    removed_record_ids = set()
    for parent in list(root.iter()):
        for element in list(parent):
            discard = element.get('id') in removed
            if element.get('class') == 'IBConnectionRecord':
                connection = element.find('./object[@key="connection"]')
                if connection is not None:
                    label = connection.find('./string[@key="label"]')
                    discard |= (label is not None and label.text in LABELS)
                    discard |= any(ref.get('ref') in removed for ref in connection.findall('reference'))
            if element.get('class') == 'IBObjectRecord':
                reference = element.find('./reference[@key="object"]')
                if reference is not None and reference.get('ref') in removed:
                    discard = True
                    removed_record_ids.add(element.find('./int[@key="objectID"]').text)
            if element.get('class') == 'IBPartialClassDescription':
                text = ET.tostring(element, encoding='unicode')
                discard |= any(name in text for name in ['Sparkle.framework/', 'SyncSessionController',
                    'SyncResponseFetcher', 'SyncServiceSessionProtocol', 'Simplenote', 'NotationSyncServiceManager'])
                discard |= any(label in text for label in LABELS)
            if element.tag == 'reference' and element.get('ref') in removed:
                discard = True
            if discard:
                if element.get('class') == 'IBPartialClassDescription':
                    removed.update(child.get('id') for child in element.iter() if child.get('id'))
                parent.remove(element)

    for element in root.iter('object'):
        if element.get('class') == 'NSTabView':
            items = element.find('./object[@key="NSTabViewItems"]')
            if items is not None:
                retained = [item for item in items if target(item)]
                if retained:
                    selected = element.find('./reference[@key="NSSelectedTabViewItem"]')
                    if selected is None:
                        ET.SubElement(element, 'reference', key='NSSelectedTabViewItem', ref=target(retained[0]))
    for element in root.iter('object'):
        if element.get('key') == 'flattenedProperties':
            keys = element.find('./object[@key="dict.sortedKeys"]')
            values = element.find('./object[@key="dict.values"]')
            if keys is not None and values is not None:
                key_entries = [child for child in keys if child.tag != 'bool']
                value_entries = [child for child in values if child.tag != 'bool']
                assert len(key_entries) == len(value_entries)
                for key, value in zip(key_entries, value_entries):
                    if (key.text or '').split('.')[0] in removed_record_ids:
                        keys.remove(key)
                        values.remove(value)

    for _ in range(20):
        present = {element.get('id') for element in root.iter() if element.get('id')}
        missing = [(parent, element) for parent in root.iter() for element in parent
                   if element.tag == 'reference' and element.get('ref') and element.get('ref') not in present]
        if not missing:
            break
        for parent, reference in missing:
            identifier = reference.get('ref')
            if any(element.get('id') == identifier for element in root.iter()):
                continue
            if identifier in removed:
                parent.remove(reference)
            elif identifier in definitions:
                replacement = copy.deepcopy(definitions[identifier])
                if reference.get('key'):
                    replacement.set('key', reference.get('key'))
                else:
                    replacement.attrib.pop('key', None)
                parent.insert(list(parent).index(reference), replacement)
                parent.remove(reference)
            else:
                raise ValueError(f'{filename}: missing {identifier}')
    else:
        raise ValueError(f'{filename}: unresolved references {[element.get("ref") for _, element in missing]}')
    ET.indent(tree, space='\t')
    text = ET.tostring(root, encoding='unicode').replace(' />', '/>')
    filename.write_text('<?xml version="1.0" encoding="UTF-8"?>\n' + text + '\n')


for filename in (ROOT / 'Resources').glob('*.lproj/*.nib/designable.nib'):
    prune(filename, filename.parent.name in ['MainMenu.nib', 'NotationPrefsView.nib'])

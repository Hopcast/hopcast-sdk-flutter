import 'package:flutter/material.dart';
import 'package:hopcast_flutter/hopcast_flutter.dart';

import '../main.dart';
import 'trust.dart';

/// The demo's single screen: live neighbours, multi-select send, and a list of
/// received files. Settings (trust policy) live behind the gear icon.
class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.controller});

  final HopcastController controller;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final Set<String> _selected = {}; // selected endpointIds
  int _fileCount = 1;

  HopcastController get c => widget.controller;

  @override
  Widget build(BuildContext context) {
    // Drop selections for peers that disappeared.
    final live = c.neighbors.map((n) => n.endpointId).toSet();
    _selected.retainWhere(live.contains);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Hopcast Demo'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'Trust settings',
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => const _SettingsPage())),
          ),
        ],
      ),
      body: _body(),
      bottomNavigationBar: c.sending != null ? _sendingBar(c.sending!) : null,
      floatingActionButton: (c.ready && _selected.isNotEmpty)
          ? FloatingActionButton.extended(
              onPressed: () {
                c.sendDemoFiles(
                    endpointIds: _selected.toList(), count: _fileCount);
              },
              icon: const Icon(Icons.send),
              label: Text('Send to ${_selected.length}'),
            )
          : null,
    );
  }

  Widget _body() {
    if (c.permissionDenied) {
      return _centered(
        icon: Icons.lock,
        title: 'Permissions required',
        message:
            'Nearby sharing needs Bluetooth / Wi-Fi / location permissions. '
            'Grant them in system settings, then relaunch.',
      );
    }
    if (!c.ready) {
      return const Center(child: CircularProgressIndicator());
    }
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (c.provisionError != null) ...[
          MaterialBanner(
            leading: const Icon(Icons.cloud_off, color: Colors.orange),
            content: Text(
                'Device enrollment failed (${c.provisionError}). Sharing is '
                'disabled until the device is provisioned — go online and '
                'relaunch.'),
            actions: const [SizedBox.shrink()],
          ),
          const SizedBox(height: 16),
        ],
        _statusCard(),
        if (c.cloudStatus != null) ...[
          const SizedBox(height: 8),
          ListTile(
            leading: const Icon(Icons.cloud),
            title: Text(c.cloudStatus!),
            subtitle: c.lastHandoff == null
                ? null
                : Text('Last instruction ${c.lastHandoff!.instructionId}: '
                    '${c.lastHandoff!.status.name}, '
                    '${c.lastHandoff!.bytesTotal ?? '?'} bytes'),
          ),
        ],
        const SizedBox(height: 16),
        _fileCountPicker(),
        const SizedBox(height: 16),
        _sectionHeader('Nearby devices', Icons.wifi_tethering),
        const SizedBox(height: 8),
        _neighborsList(),
        const SizedBox(height: 24),
        _sectionHeader('Received files', Icons.download_done),
        const SizedBox(height: 8),
        _receivedList(),
        const SizedBox(height: 80),
      ],
    );
  }

  Widget _statusCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            const CircleAvatar(child: Icon(Icons.smartphone)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('You are “${c.deviceName}”',
                      style: const TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 16)),
                  const SizedBox(height: 4),
                  Row(children: [
                    const Icon(Icons.podcasts, size: 16, color: Colors.green),
                    const SizedBox(width: 4),
                    const Text('Sharing on'),
                    const SizedBox(width: 12),
                    Icon(c.wifiOn ? Icons.wifi : Icons.wifi_off,
                        size: 16,
                        color: c.wifiOn ? Colors.green : Colors.orange),
                    const SizedBox(width: 4),
                    Text(c.wifiOn ? 'Wi-Fi on' : 'Wi-Fi off (slow)'),
                  ]),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _fileCountPicker() {
    return Row(
      children: [
        const Text('Demo files to send: '),
        const SizedBox(width: 8),
        DropdownButton<int>(
          value: _fileCount,
          items: const [1, 2, 3, 5]
              .map((n) => DropdownMenuItem(value: n, child: Text('$n')))
              .toList(),
          onChanged: (v) => setState(() => _fileCount = v ?? 1),
        ),
        const Spacer(),
        Text('~256 KB each', style: TextStyle(color: Colors.grey.shade600)),
      ],
    );
  }

  Widget _neighborsList() {
    if (c.neighbors.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2)),
            SizedBox(width: 12),
            Text('Searching for nearby devices…'),
          ],
        ),
      );
    }
    return Column(
      children: [
        for (final HopcastNeighbor n in c.neighbors)
          CheckboxListTile(
            value: _selected.contains(n.endpointId),
            onChanged: (on) => setState(() {
              if (on == true) {
                _selected.add(n.endpointId);
              } else {
                _selected.remove(n.endpointId);
              }
            }),
            secondary: const CircleAvatar(child: Icon(Icons.devices)),
            title: Text(n.displayName),
            subtitle: Text(n.endpointId,
                maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
      ],
    );
  }

  Widget _receivedList() {
    if (c.received.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text('No files received yet.',
            style: TextStyle(color: Colors.grey.shade600)),
      );
    }
    return Column(
      children: [
        if (c.incomingFraction != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: LinearProgressIndicator(value: c.incomingFraction),
          ),
        for (final f in c.received)
          ListTile(
            leading: const Icon(Icons.insert_drive_file),
            title: Text(f.name),
            subtitle: Text('From ${f.from}\n${f.path}'),
            isThreeLine: true,
          ),
      ],
    );
  }

  Widget _sendingBar(SendProgress s) {
    return Material(
      elevation: 8,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
        child: Row(
          children: [
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(s.summary ?? s.label,
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 6),
                  if (!s.done)
                    LinearProgressIndicator(value: s.fraction)
                  else
                    const SizedBox.shrink(),
                ],
              ),
            ),
            if (s.done)
              IconButton(
                icon: const Icon(Icons.close),
                onPressed: c.clearSending,
              ),
          ],
        ),
      ),
    );
  }

  Widget _sectionHeader(String title, IconData icon) {
    return Row(children: [
      Icon(icon, size: 20),
      const SizedBox(width: 8),
      Text(title,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
    ]);
  }

  Widget _centered(
      {required IconData icon,
      required String title,
      required String message}) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: Colors.grey),
            const SizedBox(height: 16),
            Text(title,
                style:
                    const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Text(message, textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}

/// Trust settings: acceptance mode + allow/block lists.
class _SettingsPage extends StatefulWidget {
  const _SettingsPage();

  @override
  State<_SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<_SettingsPage> {
  AcceptMode _mode = AcceptMode.everyone;
  Set<String> _allow = {};
  Set<String> _block = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    _mode = await Trust.instance.acceptMode();
    _allow = await Trust.instance.allowList();
    _block = await Trust.instance.blockList();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Trust settings')),
      body: ListView(
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Text('Incoming requests from unknown devices',
                style: TextStyle(fontWeight: FontWeight.bold)),
          ),
          RadioGroup<AcceptMode>(
            groupValue: _mode,
            onChanged: _setMode,
            child: const Column(
              children: [
                RadioListTile<AcceptMode>(
                  value: AcceptMode.everyone,
                  title: Text('Accept everyone'),
                  subtitle: Text('Auto-accept files from any nearby device.'),
                ),
                RadioListTile<AcceptMode>(
                  value: AcceptMode.ask,
                  title: Text('Ask each time'),
                  subtitle: Text('Prompt before accepting from a new device.'),
                ),
              ],
            ),
          ),
          const Divider(),
          _listSection('Allowed devices', _allow, Colors.green,
              onRemove: (n) async {
            await Trust.instance.clear(n);
            _load();
          }),
          _listSection('Blocked devices', _block, Colors.red,
              onRemove: (n) async {
            await Trust.instance.clear(n);
            _load();
          }),
        ],
      ),
    );
  }

  Future<void> _setMode(AcceptMode? m) async {
    if (m == null) return;
    await Trust.instance.setAcceptMode(m);
    setState(() => _mode = m);
  }

  Widget _listSection(String title, Set<String> names, Color color,
      {required Future<void> Function(String) onRemove}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
        ),
        if (names.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text('None', style: TextStyle(color: Colors.grey.shade600)),
          )
        else
          for (final n in names)
            ListTile(
              leading: Icon(Icons.circle, size: 12, color: color),
              title: Text(n),
              trailing: IconButton(
                icon: const Icon(Icons.delete_outline),
                onPressed: () => onRemove(n),
              ),
            ),
      ],
    );
  }
}

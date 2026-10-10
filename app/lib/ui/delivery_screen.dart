import 'package:flutter/material.dart';

import '../models/delivery.dart';
import 'delivery_view_model.dart';

String statusLabel(DeliveryStatus status) => switch (status) {
  DeliveryStatus.pending => '待配送',
  DeliveryStatus.completed => '已完成',
  DeliveryStatus.failed => '配送失败',
};

class DeliveryScreen extends StatelessWidget {
  const DeliveryScreen({super.key, required this.viewModel, this.demo = false});

  final DeliveryViewModel viewModel;
  final bool demo;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: viewModel,
      builder: (context, _) {
        return Scaffold(
          appBar: AppBar(title: const Text('Ocean Delivery')),
          body: SafeArea(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        demo
                            ? 'Demo · simulated acknowledgements'
                            : '本地客户端 · 服务待接入',
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        demo
                            ? 'Sample deliveries · acknowledgements are simulated.'
                            : '更新会先保存到本机；当前未连接配送服务。',
                      ),
                      const SizedBox(height: 12),
                      Wrap(
                        alignment: WrapAlignment.spaceBetween,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          Text(
                            '${viewModel.stops.length} 站 · '
                            '${viewModel.pendingCount} 待配送 · '
                            '${viewModel.queueCount} 待同步',
                          ),
                          OutlinedButton.icon(
                            onPressed:
                                viewModel.queueCount == 0 ||
                                    viewModel.isSaving ||
                                    viewModel.isSyncing ||
                                    viewModel.isLoading
                                ? null
                                : viewModel.sync,
                            icon: const Icon(Icons.sync),
                            label: Text(viewModel.isSyncing ? '同步中…' : '同步'),
                          ),
                        ],
                      ),
                      if (viewModel.syncMessage != null) ...[
                        const SizedBox(height: 8),
                        Semantics(
                          liveRegion: true,
                          child: Text(viewModel.syncMessage!),
                        ),
                      ],
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(child: _buildContent(context)),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildContent(BuildContext context) {
    if (viewModel.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (viewModel.loadError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Semantics(liveRegion: true, child: Text(viewModel.loadError!)),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: viewModel.load,
                child: const Text('重试加载'),
              ),
            ],
          ),
        ),
      );
    }
    if (viewModel.stops.isEmpty) return const Center(child: Text('暂无配送站点'));
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: viewModel.stops.length,
      separatorBuilder: (_, _) => const Divider(height: 1, indent: 16),
      itemBuilder: (context, index) {
        final stop = viewModel.stops[index];
        return ListTile(
          key: ValueKey('stop-${stop.id}'),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 8,
          ),
          title: Text(stop.customerName),
          subtitle: Text(
            '${stop.reference}\n${stop.address}\n'
            '${statusLabel(stop.status)}'
            '${viewModel.awaitsService(stop) ? ' · 本地已保存，待服务' : ''}',
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: () {
            viewModel.clearSaveError();
            Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) =>
                    DeliveryDetailScreen(viewModel: viewModel, stopId: stop.id),
              ),
            );
          },
        );
      },
    );
  }
}

class DeliveryDetailScreen extends StatefulWidget {
  const DeliveryDetailScreen({
    super.key,
    required this.viewModel,
    required this.stopId,
  });

  final DeliveryViewModel viewModel;
  final String stopId;

  @override
  State<DeliveryDetailScreen> createState() => _DeliveryDetailScreenState();
}

class _DeliveryDetailScreenState extends State<DeliveryDetailScreen> {
  final _reason = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  bool _recordingFailure = false;

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  Future<void> _submit(DeliveryStatus status) async {
    if (status == DeliveryStatus.failed && !_formKey.currentState!.validate()) {
      return;
    }
    FocusScope.of(context).unfocus();
    final saved = await widget.viewModel.submit(
      widget.stopId,
      status,
      reason: status == DeliveryStatus.failed ? _reason.text.trim() : null,
    );
    if (!mounted || !saved) return;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.viewModel,
      builder: (context, _) {
        final model = widget.viewModel;
        final stop = model.stopById(widget.stopId);
        return Scaffold(
          appBar: AppBar(title: const Text('配送详情')),
          body: stop == null
              ? const Center(child: Text('该站点无法加载，请返回列表重试。'))
              : SafeArea(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(20),
                    keyboardDismissBehavior:
                        ScrollViewKeyboardDismissBehavior.onDrag,
                    child: Form(
                      key: _formKey,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            stop.customerName,
                            style: Theme.of(context).textTheme.headlineSmall,
                          ),
                          const SizedBox(height: 8),
                          Text(stop.reference),
                          const SizedBox(height: 16),
                          Text(stop.address),
                          const SizedBox(height: 16),
                          Text(
                            statusLabel(stop.status),
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          if (model.awaitsService(stop)) ...[
                            const SizedBox(height: 8),
                            const Text('本地已保存，待服务连接后确认。'),
                          ],
                          if (stop.status == DeliveryStatus.failed) ...[
                            const SizedBox(height: 16),
                            Text('失败原因：${stop.reason ?? '来源未提供'}'),
                          ],
                          if (stop.status == DeliveryStatus.pending) ...[
                            const SizedBox(height: 24),
                            if (_recordingFailure) ...[
                              TextFormField(
                                key: const ValueKey('failure-reason'),
                                controller: _reason,
                                enabled: !model.isSaving,
                                minLines: 3,
                                maxLines: 5,
                                textInputAction: TextInputAction.done,
                                decoration: const InputDecoration(
                                  labelText: '失败原因',
                                  hintText: '例如：收件人不在，无法完成配送',
                                ),
                                onTapOutside: (_) =>
                                    FocusScope.of(context).unfocus(),
                                validator: (value) =>
                                    value == null || value.trim().isEmpty
                                    ? '请填写失败原因'
                                    : null,
                              ),
                              const SizedBox(height: 16),
                              FilledButton(
                                onPressed: model.isSaving
                                    ? null
                                    : () => _submit(DeliveryStatus.failed),
                                child: Text(model.isSaving ? '保存中…' : '保存配送失败'),
                              ),
                              TextButton(
                                onPressed: model.isSaving
                                    ? null
                                    : () => setState(
                                        () => _recordingFailure = false,
                                      ),
                                child: const Text('取消记录失败'),
                              ),
                            ] else ...[
                              FilledButton.icon(
                                onPressed: model.isSaving
                                    ? null
                                    : () => _submit(DeliveryStatus.completed),
                                icon: const Icon(Icons.check),
                                label: Text(model.isSaving ? '保存中…' : '标记已完成'),
                              ),
                              const SizedBox(height: 8),
                              OutlinedButton(
                                onPressed: model.isSaving
                                    ? null
                                    : () => setState(
                                        () => _recordingFailure = true,
                                      ),
                                child: const Text('记录配送失败'),
                              ),
                            ],
                            if (model.saveError != null) ...[
                              const SizedBox(height: 16),
                              Semantics(
                                liveRegion: true,
                                child: Text(
                                  model.saveError!,
                                  style: TextStyle(
                                    color: Theme.of(context).colorScheme.error,
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
        );
      },
    );
  }
}

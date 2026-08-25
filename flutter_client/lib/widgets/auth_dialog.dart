import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/music_api_service.dart';
import '../theme/app_theme.dart';

class AuthDialog extends StatefulWidget {
  final VoidCallback onLoginChanged;
  const AuthDialog({super.key, required this.onLoginChanged});

  static Future<void> show(BuildContext context, VoidCallback onLoginChanged) {
    return showDialog(
      context: context,
      barrierColor: Colors.black.withOpacity(0.5),
      builder: (ctx) => AuthDialog(onLoginChanged: onLoginChanged),
    );
  }

  @override
  State<AuthDialog> createState() => _AuthDialogState();
}

class _AuthDialogState extends State<AuthDialog> {
  bool _isLoading = true;
  bool _isLoggedIn = false;
  Map<String, dynamic>? _userData;
  Map<String, dynamic>? _vipData;

  // 登录表单状态
  int _activeTab = 0; // 0: 手机号登录, 1: 扫码登录
  final TextEditingController _phoneController = TextEditingController();
  final TextEditingController _codeController = TextEditingController();
  int _countdown = 0;
  Timer? _countdownTimer;
  Timer? _qrPollingTimer;
  bool _isSubmitting = false;
  bool _qrChecking = false;

  // 扫码登录状态
  String? _qrKey;
  String? _qrImageBase64;
  String _qrStatusMsg = "请使用酷狗音乐 App 扫码登录";

  @override
  void initState() {
    super.initState();
    _checkLoginStatus();
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    _qrPollingTimer?.cancel();
    _phoneController.dispose();
    _codeController.dispose();
    super.dispose();
  }

  // 登录方式文本（对应 Go 版 saveLoginMethodToFile / readLoginMethodFromFile）
  String _loginMethodText() {
    var method = 'unknown';
    final cached = _prefsCache;
    if (cached != null) {
      method = cached.getString('login_method') ?? 'unknown';
    }
    return switch (method) {
      'phone' => '手机号登录',
      'qrcode' => '扫码登录',
      _ => '在线云认证',
    };
  }

  static SharedPreferences? _prefsCache;

  Future<void> _checkLoginStatus() async {
    setState(() => _isLoading = true);
    final prefs = await SharedPreferences.getInstance();
    _prefsCache = prefs;
    final userRes = await MusicApiService.getUserDetail();
    if (userRes['success'] == true && userRes['data'] != null) {
      final vipRes = await MusicApiService.getVipDetail();
      if (mounted) {
        setState(() {
          _isLoggedIn = true;
          _userData = userRes['data'];
          if (vipRes['success'] == true) {
            _vipData = vipRes['data'];
          }
          _isLoading = false;
        });
      }
    } else {
      if (mounted) {
        setState(() {
          _isLoggedIn = false;
          _isLoading = false;
        });
      }
    }
  }

  // 后台异步补充 VIP 详情（失败不影响登录态展示）
  Future<void> _refreshVipDetail() async {
    try {
      final vipRes = await MusicApiService.getVipDetail();
      if (!mounted) return;
      if (vipRes['success'] == true && vipRes['data'] != null) {
        setState(() => _vipData = vipRes['data']);
      }
    } catch (_) {}
  }

  // 发送验证码
  Future<void> _sendCaptcha() async {
    final phone = _phoneController.text.trim();
    if (phone.length != 11 || !RegExp(r'^1[3-9]\d{9}$').hasMatch(phone)) {
      _showToast("请输入有效的11位手机号");
      return;
    }

    setState(() => _countdown = 60);
    _countdownTimer?.cancel();
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) return;
      if (_countdown > 1) {
        setState(() => _countdown--);
      } else {
        timer.cancel();
        setState(() => _countdown = 0);
      }
    });

    final res = await MusicApiService.sendCaptcha(phone);
    if (res['error_code'] == 0 || res['status'] == 1) {
      _showToast("验证码已发送，请查收");
    } else {
      _showToast(res['message'] ?? res['msg'] ?? "验证码发送失败");
    }
  }

  // 手机号登录
  Future<void> _submitPhoneLogin() async {
    final phone = _phoneController.text.trim();
    final code = _codeController.text.trim();
    if (phone.isEmpty || code.isEmpty) {
      _showToast("请填写完整的手机号与验证码");
      return;
    }

    setState(() => _isSubmitting = true);
    final res = await MusicApiService.loginWithPhone(phone, code);
    setState(() => _isSubmitting = false);

    if (res['success'] == true) {
      // 与原版 Go 版 loginSuccess 一致：直接使用登录响应的用户信息更新界面，
      // 不依赖 getUserDetail 二次校验。
      final data = res['data'];
      final userData = data is Map
          ? Map<String, dynamic>.from(data)
          : <String, dynamic>{};
      setState(() {
        _isLoggedIn = true;
        _isLoading = false;
        _userData = userData;
        _vipData = null;
      });
      _showToast("登录成功！");
      widget.onLoginChanged();
      // 后台异步补充 VIP 详情（失败不影响登录态展示）。
      unawaited(_refreshVipDetail());
    } else {
      _showToast(res['message'] ?? "登录失败，请检查验证码");
    }
  }

  // 初始化二维码
  Future<void> _initQRCode() async {
    _qrLog('开始刷新二维码');
    _qrPollingTimer?.cancel();
    setState(() {
      _qrKey = null;
      _qrImageBase64 = null;
      _qrStatusMsg = "正在生成登录二维码...";
    });

    final keyRes = await MusicApiService.generateQRKey();
    final keyData = keyRes['data'];
    final key = keyData is Map ? (keyData['qrcode'] ?? keyData['key']) : null;
    if (key == null || key.toString().trim().isEmpty) {
      _qrLog('二维码 Key 获取失败: ${keyRes['message'] ?? keyRes['msg'] ?? '无 Key'}');
      if (mounted) {
        setState(() =>
            _qrStatusMsg = keyRes['message']?.toString() ?? '生成二维码失败，请重试');
      }
      return;
    }

    _qrKey = key.toString();
    _qrLog('二维码 Key 获取成功: ${_maskQrKey(_qrKey!)}');
    final createRes = await MusicApiService.createQRCode(_qrKey!);
    final createData = createRes['data'];
    final base64Str = createData is Map
        ? (createData['base64'] ?? createData['qrimg'])
        : null;
    if (base64Str == null || base64Str.toString().trim().isEmpty) {
      _qrLog('二维码图片获取失败: ${createRes['message'] ?? createRes['msg'] ?? '无图片'}');
      if (mounted) {
        setState(() =>
            _qrStatusMsg = createRes['message']?.toString() ?? '二维码图片生成失败，请刷新');
      }
      return;
    }

    if (mounted) {
      setState(() {
        _qrImageBase64 = base64Str.toString();
        _qrStatusMsg = '请使用酷狗音乐 App 扫码登录';
      });
    }

    _qrLog('二维码图片已显示，开始轮询扫码状态');
    _startQRPolling();
  }

  void _startQRPolling() {
    _qrLog('扫码状态轮询已启动，间隔 3 秒');
    _qrPollingTimer?.cancel();
    _qrPollingTimer = Timer.periodic(const Duration(seconds: 3), (timer) async {
      if (!mounted || _qrKey == null) {
        timer.cancel();
        return;
      }
      if (_qrChecking) return;
      _qrChecking = true;
      try {
        final checkRes = await MusicApiService.checkQRStatus(_qrKey!);
        final data = checkRes['data'];
        final status =
            data is Map ? int.tryParse('${data['status']}') ?? -1 : -1;

        if (!mounted) return;
        _qrLog('UI 收到二维码状态: $status');
        if (status == 4) {
          _qrLog('UI 确认扫码成功，停止轮询并切换到用户信息');
          timer.cancel();
          _qrPollingTimer = null;
          // 与原版 Go 版 loginSuccess 一致：直接使用扫码响应中的
          // nickname/pic/userid 更新界面，不依赖 getUserDetail 二次校验。
          final userData = Map<String, dynamic>.from(data as Map);
          setState(() {
            _isLoggedIn = true;
            _isLoading = false;
            _userData = userData;
            _vipData = null;
          });
          _showToast('扫码登录成功！');
          widget.onLoginChanged();
          // 后台异步补充 VIP 详情（失败不影响登录态展示）。
          unawaited(_refreshVipDetail());
        } else if (status == 0) {
          timer.cancel();
          setState(() => _qrStatusMsg = '二维码已过期，点击刷新');
        } else if (status == 2) {
          setState(() => _qrStatusMsg = '已扫码，请在手机上确认');
        } else if (status == 1) {
          setState(() => _qrStatusMsg = '请使用酷狗音乐 App 扫码登录');
        } else if (checkRes['message'] != null) {
          setState(() => _qrStatusMsg = checkRes['message'].toString());
        }
      } finally {
        _qrChecking = false;
      }
    });
  }

  // 领取每日VIP
  Future<void> _claimVip() async {
    final res = await MusicApiService.claimDailyVip();
    if (res['status'] == 1 || res['error_code'] == 0) {
      _showToast("领取成功！");
      _checkLoginStatus();
    } else {
      _showToast(res['msg'] ?? res['message'] ?? "今日已领取或领取失败");
    }
  }

  // 退出登录
  Future<void> _logout() async {
    await MusicApiService.logout();
    widget.onLoginChanged();
    if (mounted) {
      setState(() {
        _isLoggedIn = false;
        _userData = null;
        _vipData = null;
      });
      _showToast("已退出登录");
    }
  }

  void _qrLog(String message) {
    print('[扫码登录 UI] $message');
  }

  String _maskQrKey(String key) {
    if (key.length <= 8) return '***';
    return '${key.substring(0, 4)}...${key.substring(key.length - 4)}';
  }

  void _showToast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      backgroundColor: Colors.white,
      insetPadding: const EdgeInsets.symmetric(horizontal: 40, vertical: 24),
      child: Container(
        width: 420,
        padding: const EdgeInsets.all(24),
        child: _isLoading
            ? SizedBox(
                height: 200,
                child: Center(
                  child:
                      CircularProgressIndicator(color: AppTheme.accentOrange),
                ),
              )
            : _isLoggedIn
                ? _buildUserProfileView()
                : _buildLoginView(),
      ),
    );
  }

  // 用户详情视图
  Widget _buildUserProfileView() {
    final nickname = _userData?['nickname'] ?? '酷狗用户';
    final pic = _userData?['pic'] ?? '';
    final userid = _userData?['userid'] ?? _userData?['userId'] ?? '-';
    final isVip =
        (_userData?['vip_type'] ?? 0) > 0 || (_vipData?['is_vip'] ?? 0) == 1;
    final vipEndTime = _vipData?['vip_end_time'] ?? '-';
    final vipType = _vipData?['product_type'] ?? '-';
    // 登录时间（秒时间戳），对应 Go 版 userInfo.userData.login_time
    final loginTimeRaw = _userData?['login_time'];
    final loginTime = loginTimeRaw is num && loginTimeRaw > 0
        ? DateTime.fromMillisecondsSinceEpoch(loginTimeRaw.toInt() * 1000)
        : null;
    final loginTimeText = loginTime == null
        ? '-'
        : '${loginTime.year}-${loginTime.month.toString().padLeft(2, '0')}-'
            '${loginTime.day.toString().padLeft(2, '0')} '
            '${loginTime.hour.toString().padLeft(2, '0')}:'
            '${loginTime.minute.toString().padLeft(2, '0')}';
    // 登录方式（对应 Go 版 saveLoginMethodToFile / readLoginMethodFromFile）
    final loginMethod = _loginMethodText();

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 头部
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              "用户信息",
              style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: AppTheme.textPrimary),
            ),
            IconButton(
              icon: const Icon(Icons.close, size: 20),
              onPressed: () => Navigator.of(context).pop(),
            ),
          ],
        ),
        const SizedBox(height: 16),

        // 用户头像与基本信息
        Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(32),
              child: pic.isNotEmpty
                  ? Image.network(pic,
                      width: 64,
                      height: 64,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => _defaultAvatar())
                  : _defaultAvatar(),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    nickname,
                    style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: AppTheme.textPrimary),
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: isVip
                              ? const Color(0xFFFFECE5)
                              : Colors.grey.shade100,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                              color: isVip
                                  ? AppTheme.accentOrange
                                  : Colors.grey.shade300),
                        ),
                        child: Text(
                          isVip ? "VIP 尊贵用户" : "普通用户",
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: isVip
                                ? AppTheme.accentOrange
                                : AppTheme.textSecondary,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      InkWell(
                        onTap: _claimVip,
                        borderRadius: BorderRadius.circular(10),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            gradient: const LinearGradient(
                                colors: [Color(0xFFE87A43), Color(0xFFFF955C)]),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: const Row(
                            children: [
                              Icon(Icons.card_giftcard,
                                  size: 12, color: Colors.white),
                              SizedBox(width: 4),
                              Text("领取VIP",
                                  style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600)),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),
        const Divider(height: 1),
        const SizedBox(height: 16),

        // 用户详细列表项（与原版 Go 用户信息弹窗一致）
        _detailRow("用户 ID", "$userid"),
        _detailRow("登录方式", loginMethod),
        _detailRow("登录时间", loginTimeText),
        if (isVip) ...[
          _detailRow("VIP类型", vipType),
          _detailRow("VIP 到期时间", vipEndTime),
        ],

        const SizedBox(height: 24),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            OutlinedButton(
              onPressed: _logout,
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.red.shade400,
                side: BorderSide(color: Colors.red.shade200),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8)),
              ),
              child: const Text("退出登录"),
            ),
            const SizedBox(width: 12),
            ElevatedButton(
              onPressed: () => Navigator.of(context).pop(),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.accentOrange,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8)),
              ),
              child: const Text("确定"),
            ),
          ],
        ),
      ],
    );
  }

  Widget _detailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label,
              style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
          Text(value,
              style: TextStyle(
                  fontSize: 13,
                  color: AppTheme.textPrimary,
                  fontWeight: FontWeight.w500)),
        ],
      ),
    );
  }

  Widget _defaultAvatar() {
    return Container(
      width: 64,
      height: 64,
      color: Colors.grey.shade200,
      child: const Icon(Icons.person, size: 36, color: Colors.grey),
    );
  }

  // 登录视图 (手机号 + 扫码登录)
  Widget _buildLoginView() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              "登录 MusicHub",
              style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: AppTheme.textPrimary),
            ),
            IconButton(
              icon: const Icon(Icons.close, size: 20),
              onPressed: () => Navigator.of(context).pop(),
            ),
          ],
        ),
        const SizedBox(height: 12),

        // Tabs
        Container(
          decoration: BoxDecoration(
            color: Colors.grey.shade100,
            borderRadius: BorderRadius.circular(8),
          ),
          padding: const EdgeInsets.all(3),
          child: Row(
            children: [
              Expanded(
                child: GestureDetector(
                  onTap: () {
                    _qrPollingTimer?.cancel();
                    setState(() => _activeTab = 0);
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    decoration: BoxDecoration(
                      color:
                          _activeTab == 0 ? Colors.white : Colors.transparent,
                      borderRadius: BorderRadius.circular(6),
                      boxShadow: _activeTab == 0
                          ? [
                              const BoxShadow(
                                  color: Color(0x10000000), blurRadius: 4)
                            ]
                          : null,
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      "手机号登录",
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: _activeTab == 0
                            ? FontWeight.bold
                            : FontWeight.normal,
                        color: _activeTab == 0
                            ? AppTheme.accentOrange
                            : AppTheme.textSecondary,
                      ),
                    ),
                  ),
                ),
              ),
              Expanded(
                child: GestureDetector(
                  onTap: () {
                    setState(() => _activeTab = 1);
                    _initQRCode();
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    decoration: BoxDecoration(
                      color:
                          _activeTab == 1 ? Colors.white : Colors.transparent,
                      borderRadius: BorderRadius.circular(6),
                      boxShadow: _activeTab == 1
                          ? [
                              const BoxShadow(
                                  color: Color(0x10000000), blurRadius: 4)
                            ]
                          : null,
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      "扫码登录",
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: _activeTab == 1
                            ? FontWeight.bold
                            : FontWeight.normal,
                        color: _activeTab == 1
                            ? AppTheme.accentOrange
                            : AppTheme.textSecondary,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),

        if (_activeTab == 0)
          _buildPhoneLoginForm()
        else
          _buildQrCodeLoginForm(),
      ],
    );
  }

  // 手机号登录表单
  Widget _buildPhoneLoginForm() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text("手机号码",
            style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: AppTheme.textPrimary)),
        const SizedBox(height: 6),
        TextField(
          controller: _phoneController,
          keyboardType: TextInputType.phone,
          decoration: InputDecoration(
            hintText: "请输入11位手机号",
            hintStyle: TextStyle(fontSize: 13, color: AppTheme.textSecondary),
            prefixIcon: Icon(Icons.phone_iphone,
                size: 18, color: AppTheme.textSecondary),
            contentPadding:
                const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
            border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide(color: Colors.grey.shade300)),
            focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide(color: AppTheme.accentOrange)),
          ),
          style: const TextStyle(fontSize: 13),
        ),
        const SizedBox(height: 14),
        Text("验证码",
            style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: AppTheme.textPrimary)),
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _codeController,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  hintText: "请输入6位验证码",
                  hintStyle:
                      TextStyle(fontSize: 13, color: AppTheme.textSecondary),
                  prefixIcon: Icon(Icons.lock_outline,
                      size: 18, color: AppTheme.textSecondary),
                  contentPadding:
                      const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(color: Colors.grey.shade300)),
                  focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(color: AppTheme.accentOrange)),
                ),
                style: const TextStyle(fontSize: 13),
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              height: 42,
              child: OutlinedButton(
                onPressed: _countdown > 0 ? null : _sendCaptcha,
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppTheme.accentOrange,
                  side: BorderSide(color: AppTheme.accentOrange),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8)),
                ),
                child: Text(_countdown > 0 ? "${_countdown}s 后重发" : "发送验证码",
                    style: const TextStyle(fontSize: 12)),
              ),
            ),
          ],
        ),
        const SizedBox(height: 24),
        SizedBox(
          width: double.infinity,
          height: 42,
          child: ElevatedButton(
            onPressed: _isSubmitting ? null : _submitPhoneLogin,
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.accentOrange,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8)),
            ),
            child: _isSubmitting
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white))
                : const Text("登录",
                    style:
                        TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
          ),
        ),
      ],
    );
  }

  // 扫码登录表单
  Widget _buildQrCodeLoginForm() {
    return Center(
      child: Column(
        children: [
          Container(
            width: 170,
            height: 170,
            decoration: BoxDecoration(
              color: Colors.grey.shade100,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.grey.shade300),
            ),
            child: _qrImageBase64 != null
                ? InkWell(
                    onTap: _initQRCode,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: Image.memory(
                        base64Decode(_qrImageBase64!.split(',').last),
                        fit: BoxFit.cover,
                      ),
                    ),
                  )
                : Center(
                    child:
                        CircularProgressIndicator(color: AppTheme.accentOrange),
                  ),
          ),
          const SizedBox(height: 12),
          Text(
            _qrStatusMsg,
            style: TextStyle(fontSize: 13, color: AppTheme.textSecondary),
          ),
          const SizedBox(height: 6),
          TextButton(
            onPressed: _initQRCode,
            child: Text("刷新二维码",
                style: TextStyle(color: AppTheme.accentOrange, fontSize: 12)),
          ),
        ],
      ),
    );
  }
}

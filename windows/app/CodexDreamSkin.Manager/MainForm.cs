using System.Diagnostics;
using System.Drawing.Drawing2D;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Windows.Forms.Integration;
using WpfMediaElement = System.Windows.Controls.MediaElement;
using WpfMediaState = System.Windows.Controls.MediaState;
using WpfStretch = System.Windows.Media.Stretch;

namespace CodexDreamSkin.Manager;

internal sealed class MainForm : Form
{
  private const string DisplayName = "Codex 动态壁纸";
  private static readonly Color Canvas = Color.FromArgb(17, 19, 24);
  private static readonly Color Surface = Color.FromArgb(25, 28, 35);
  private static readonly Color SurfaceRaised = Color.FromArgb(34, 38, 47);
  private static readonly Color SurfaceHover = Color.FromArgb(44, 48, 58);
  private static readonly Color Accent = Color.FromArgb(225, 105, 131);
  private static readonly Color AccentHover = Color.FromArgb(240, 124, 149);
  private static readonly Color TextPrimary = Color.FromArgb(244, 240, 243);
  private static readonly Color TextMuted = Color.FromArgb(167, 170, 180);
  private static readonly Color Success = Color.FromArgb(103, 211, 155);
  private static readonly Color Warning = Color.FromArgb(245, 190, 83);

  private readonly DreamSkinService _service;
  private readonly SettingsStore _settingsStore;
  private readonly WallpaperCatalog _catalog = new();
  private readonly AppSettings _settings;
  private readonly CancellationTokenSource _lifetime = new();
  private readonly System.Windows.Forms.Timer _statusTimer = new() { Interval = 4000 };
  private readonly System.Windows.Forms.Timer _searchTimer = new() { Interval = 350 };
  private readonly NotifyIcon _trayIcon;
  private readonly Icon _appIcon;
  private readonly ToolTip _toolTip = new();

  private readonly FlowLayoutPanel _libraryFlow = new();
  private readonly TextBox _searchBox = new();
  private readonly Label _librarySummary = new();
  private readonly Label _statusLabel = new();
  private readonly Panel _statusDot = new();
  private readonly Button _startButton = new();
  private readonly Button _importButton = new();
  private readonly Button _pauseButton = new();
  private readonly Button _themesButton = new();
  private readonly Button _wallpaperEngineButton = new();
  private readonly Button _applyButton = new();
  private readonly Button _restoreButton = new();
  private readonly TrackBar _revealSlider = new();
  private readonly Label _revealLabel = new();
  private readonly TrackBar _panelSlider = new();
  private readonly Label _panelLabel = new();
  private readonly Label _selectionTitle = new();
  private readonly Label _selectionMeta = new();
  private readonly Label _messageLabel = new();
  private readonly Label _libraryPathLabel = new();
  private readonly CheckBox _autoStartCheckBox = new();
  private readonly PictureBox _previewImage = new();
  private readonly ElementHost _videoHost = new();
  private readonly WpfMediaElement _mediaElement = new();

  private WallpaperItem? _selectedWallpaper;
  private Control? _selectedCard;
  private CancellationTokenSource? _libraryLoad;
  private bool _busy;
  private bool _allowExit;
  private bool _initializing = true;
  private bool _pauseRequested;

  public MainForm(DreamSkinService service, SettingsStore settingsStore, bool minimized)
  {
    _service = service;
    _settingsStore = settingsStore;
    _settings = settingsStore.Load();
    Directory.CreateDirectory(_settings.LibraryPath);

    Text = DisplayName;
    StartPosition = FormStartPosition.CenterScreen;
    MinimumSize = new Size(1060, 680);
    Size = new Size(1280, 800);
    BackColor = Canvas;
    ForeColor = TextPrimary;
    Font = new Font("Segoe UI Variable Text", 10f, FontStyle.Regular, GraphicsUnit.Point);
    DoubleBuffered = true;
    _appIcon = CreateAppIcon();
    Icon = _appIcon;
    SetDarkTitleBar(Handle);

    BuildLayout();
    ApplyHighDpiScaling();
    _service.ConfirmCodexRestart = ConfirmCodexRestart;
    _trayIcon = BuildTrayIcon();
    _statusTimer.Tick += (_, _) => RefreshStatus();
    _searchTimer.Tick += async (_, _) =>
    {
      _searchTimer.Stop();
      await ReloadLibraryAsync();
    };

    Shown += async (_, _) =>
    {
      _initializing = false;
      _autoStartCheckBox.Checked = AutoStartManager.IsEnabled();
      try
      {
        await _service.RestoreActiveSceneAsync(_lifetime.Token);
      }
      catch (OperationCanceledException exception)
      {
        ShowMessage(exception.Message, false);
      }
      catch (Exception exception)
      {
        ShowError(exception);
      }
      RefreshStatus();
      await ReloadLibraryAsync();
      _statusTimer.Start();
      if (minimized)
      {
        Hide();
      }
    };
    FormClosing += OnFormClosing;
  }

  protected override void Dispose(bool disposing)
  {
    if (disposing)
    {
      _lifetime.Cancel();
      _libraryLoad?.Cancel();
      _statusTimer.Dispose();
      _searchTimer.Dispose();
      _toolTip.Dispose();
      StopVideoPreview();
      _trayIcon.Dispose();
      _appIcon.Dispose();
      _service.Dispose();
      _lifetime.Dispose();
      _libraryLoad?.Dispose();
    }
    base.Dispose(disposing);
  }

  private void BuildLayout()
  {
    var header = new Panel
    {
      Dock = DockStyle.Top,
      Height = 88,
      BackColor = Surface,
      Padding = new Padding(26, 14, 22, 12),
    };
    // TableLayoutPanel replaces the hand-coded Right-anchored coordinates that
    // broke at high DPI: absolute column widths still scale with AutoScaleMode,
    // and the brand cell absorbs all remaining space.
    var headerTable = new TableLayoutPanel
    {
      Dock = DockStyle.Fill,
      ColumnCount = 4,
      RowCount = 1,
      BackColor = Surface,
    };
    headerTable.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
    headerTable.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 18));
    headerTable.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 288));
    headerTable.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 158));
    headerTable.RowStyles.Add(new RowStyle(SizeType.Percent, 100));

    var brand = CreateLabel(DisplayName, 20f, FontStyle.Bold, TextPrimary);
    brand.AutoSize = true;
    brand.Anchor = AnchorStyles.Left;
    headerTable.Controls.Add(brand, 0, 0);

    _statusDot.Size = new Size(10, 10);
    _statusDot.BackColor = Warning;
    _statusDot.Anchor = AnchorStyles.Left;
    headerTable.Controls.Add(_statusDot, 1, 0);

    _statusLabel.AutoSize = false;
    _statusLabel.Dock = DockStyle.Fill;
    _statusLabel.ForeColor = TextMuted;
    _statusLabel.TextAlign = ContentAlignment.MiddleLeft;
    _statusLabel.Text = "正在读取状态\r\n当前壁纸：正在读取";
    _statusLabel.AutoEllipsis = true;
    _statusLabel.AccessibleName = "Codex 和动态壁纸运行状态";
    headerTable.Controls.Add(_statusLabel, 2, 0);

    ConfigureButton(_startButton, "启动 / 重新应用", true);
    _startButton.Size = new Size(150, 42);
    _startButton.Anchor = AnchorStyles.None;
    _startButton.AccessibleName = "启动或重新应用 Codex 动态壁纸";
    _startButton.Click += async (_, _) => await RunOperationAsync(
      "正在启动 Codex 动态壁纸…",
      () => _service.StartAsync(_lifetime.Token),
      "Codex 动态壁纸已启动。");
    headerTable.Controls.Add(_startButton, 3, 0);

    header.Controls.Add(headerTable);
    EnableDoubleBuffering(headerTable);

    var left = new Panel
    {
      Dock = DockStyle.Fill,
      Margin = new Padding(0),
      MinimumSize = new Size(180, 0),
      BackColor = Surface,
      Padding = new Padding(18, 22, 18, 18),
    };
    var libraryHeading = CreateLabel("壁纸库", 10f, FontStyle.Bold, TextMuted);
    libraryHeading.Dock = DockStyle.Top;
    libraryHeading.Height = 28;
    left.Controls.Add(libraryHeading);

    _libraryPathLabel.Dock = DockStyle.Top;
    _libraryPathLabel.Height = 58;
    _libraryPathLabel.ForeColor = TextPrimary;
    _libraryPathLabel.Text = CompactPath(_settings.LibraryPath);
    _libraryPathLabel.AutoEllipsis = true;
    _libraryPathLabel.AccessibleName = "当前壁纸库路径";
    _toolTip.SetToolTip(_libraryPathLabel, _settings.LibraryPath);
    left.Controls.Add(_libraryPathLabel);
    left.Controls.SetChildIndex(_libraryPathLabel, 0);

    ConfigureButton(_importButton, "添加壁纸", true);
    _importButton.Dock = DockStyle.Top;
    _importButton.Height = 40;
    _importButton.AccessibleName = "添加图片或视频壁纸";
    _importButton.Click += async (_, _) => await ImportWallpapersAsync();
    left.Controls.Add(_importButton);
    left.Controls.SetChildIndex(_importButton, 0);

    var chooseFolderButton = new Button();
    ConfigureButton(chooseFolderButton, "更换壁纸库", false);
    chooseFolderButton.Dock = DockStyle.Top;
    chooseFolderButton.Height = 38;
    chooseFolderButton.Click += async (_, _) => await ChooseLibraryAsync();
    left.Controls.Add(chooseFolderButton);
    left.Controls.SetChildIndex(chooseFolderButton, 0);

    var openFolderButton = new Button();
    ConfigureButton(openFolderButton, "打开文件夹", false);
    openFolderButton.Dock = DockStyle.Top;
    openFolderButton.Height = 38;
    openFolderButton.Margin = new Padding(0, 8, 0, 0);
    openFolderButton.Click += (_, _) => OpenLibraryFolder();
    left.Controls.Add(openFolderButton);
    left.Controls.SetChildIndex(openFolderButton, 0);

    var actionsHeading = CreateLabel("控制", 10f, FontStyle.Bold, TextMuted);
    actionsHeading.Dock = DockStyle.Top;
    actionsHeading.Height = 44;
    actionsHeading.Padding = new Padding(0, 18, 0, 0);
    left.Controls.Add(actionsHeading);
    left.Controls.SetChildIndex(actionsHeading, 0);

    ConfigureButton(_pauseButton, "暂停皮肤", false);
    _pauseButton.Dock = DockStyle.Top;
    _pauseButton.Height = 38;
    _pauseButton.Click += async (_, _) =>
    {
      var nextPaused = !_pauseRequested;
      await RunOperationAsync(
        nextPaused ? "正在暂停皮肤…" : "正在恢复皮肤…",
        () => _service.SetPausedAsync(nextPaused, _lifetime.Token),
        nextPaused ? "皮肤已暂停。" : "皮肤已恢复。");
    };
    left.Controls.Add(_pauseButton);
    left.Controls.SetChildIndex(_pauseButton, 0);

    ConfigureButton(_themesButton, "已保存主题", false);
    _themesButton.Dock = DockStyle.Top;
    _themesButton.Height = 38;
    _themesButton.AccessibleName = "管理已保存主题";
    _themesButton.Click += (_, _) => ShowSavedThemes();
    left.Controls.Add(_themesButton);
    left.Controls.SetChildIndex(_themesButton, 0);

    ConfigureButton(_wallpaperEngineButton, "Wallpaper Engine", false);
    _wallpaperEngineButton.Dock = DockStyle.Top;
    _wallpaperEngineButton.Height = 38;
    _wallpaperEngineButton.AccessibleName = "选择本机已下载的 Wallpaper Engine 视频";
    _wallpaperEngineButton.Click += async (_, _) => await ShowWallpaperEngineAsync();
    left.Controls.Add(_wallpaperEngineButton);
    left.Controls.SetChildIndex(_wallpaperEngineButton, 0);

    ConfigureButton(_restoreButton, "恢复官方外观", false, danger: true);
    _restoreButton.Dock = DockStyle.Top;
    _restoreButton.Height = 38;
    _restoreButton.Click += async (_, _) => await RestoreAsync();
    left.Controls.Add(_restoreButton);
    left.Controls.SetChildIndex(_restoreButton, 0);

    _autoStartCheckBox.Dock = DockStyle.Bottom;
    _autoStartCheckBox.Height = 42;
    _autoStartCheckBox.Text = "开机启动管理器";
    _autoStartCheckBox.ForeColor = TextMuted;
    _autoStartCheckBox.FlatStyle = FlatStyle.Flat;
    _autoStartCheckBox.CheckedChanged += (_, _) =>
    {
      if (_initializing)
      {
        return;
      }
      try
      {
        AutoStartManager.SetEnabled(_autoStartCheckBox.Checked);
        _settings.StartWithWindows = _autoStartCheckBox.Checked;
        _settingsStore.Save(_settings);
        ShowMessage(_autoStartCheckBox.Checked ? "已开启开机启动。" : "已关闭开机启动。", false);
      }
      catch (Exception exception)
      {
        ShowError(exception);
      }
    };
    left.Controls.Add(_autoStartCheckBox);
    EnableDoubleBuffering(left);

    var preview = BuildPreviewPanel();
    var library = BuildLibraryPanel();

    // Proportional three-pane root: sidebar and preview keep their design ratio
    // (18%/28% ≈ the old 224px/360px at the 1280px design width), the library
    // column takes the rest. MinimumSize floors keep the panes from collapsing.
    var rootPane = new TableLayoutPanel
    {
      Dock = DockStyle.Fill,
      ColumnCount = 3,
      RowCount = 1,
      BackColor = Canvas,
    };
    rootPane.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 18));
    rootPane.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 54));
    rootPane.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 28));
    rootPane.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
    rootPane.Controls.Add(left, 0, 0);
    rootPane.Controls.Add(library, 1, 0);
    rootPane.Controls.Add(preview, 2, 0);
    EnableDoubleBuffering(rootPane);

    Controls.Add(rootPane);
    Controls.Add(header);
  }

  private void ApplyHighDpiScaling()
  {
    // Assign AutoScaleDimensions AFTER every child exists: the assignment arms
    // required-scaling, and the next layout pass scales the whole tree by
    // CurrentAutoScaleDimensions / AutoScaleDimensions (2.0 at 200% DPI).
    // Assigning it while the form is empty would consume the flag and leave
    // every control unscaled.
    AutoScaleMode = AutoScaleMode.Dpi;
    AutoScaleDimensions = new SizeF(96F, 96F);
    ResumeLayout(false);
    PerformLayout();
  }

  private Control BuildLibraryPanel()
  {
    var panel = new Panel
    {
      Dock = DockStyle.Fill,
      BackColor = Canvas,
      Padding = new Padding(24, 20, 12, 16),
    };
    var top = new Panel { Dock = DockStyle.Top, Height = 58, BackColor = Canvas };
    var title = CreateLabel("我的壁纸", 17f, FontStyle.Bold, TextPrimary);
    title.AutoSize = true;
    title.Location = new Point(0, 2);
    top.Controls.Add(title);
    _librarySummary.AutoSize = true;
    _librarySummary.ForeColor = TextMuted;
    _librarySummary.Location = new Point(2, 34);
    _librarySummary.Text = "正在读取…";
    top.Controls.Add(_librarySummary);

    _searchBox.PlaceholderText = "搜索壁纸…";
    _searchBox.BorderStyle = BorderStyle.FixedSingle;
    _searchBox.BackColor = SurfaceRaised;
    _searchBox.ForeColor = TextPrimary;
    _searchBox.Size = new Size(240, 34);
    _searchBox.Anchor = AnchorStyles.Top | AnchorStyles.Right;
    _searchBox.Location = new Point(top.Width - 240, 9);
    _searchBox.AccessibleName = "搜索壁纸";
    _searchBox.TextChanged += (_, _) =>
    {
      _searchTimer.Stop();
      _searchTimer.Start();
    };
    top.Controls.Add(_searchBox);
    top.Resize += (_, _) => _searchBox.Left = top.ClientSize.Width - _searchBox.Width;

    _libraryFlow.Dock = DockStyle.Fill;
    _libraryFlow.AutoScroll = true;
    _libraryFlow.WrapContents = true;
    _libraryFlow.FlowDirection = FlowDirection.LeftToRight;
    _libraryFlow.BackColor = Canvas;
    _libraryFlow.Padding = new Padding(0, 8, 4, 12);
    _libraryFlow.AccessibleName = "壁纸列表";
    _libraryFlow.Resize += (_, _) => LayoutLibraryCards();
    EnableDoubleBuffering(_libraryFlow);
    panel.Controls.Add(_libraryFlow);
    panel.Controls.Add(top);
    return panel;
  }

  private Control BuildPreviewPanel()
  {
    var panel = new Panel
    {
      Dock = DockStyle.Fill,
      Margin = new Padding(0),
      MinimumSize = new Size(285, 0),
      BackColor = Surface,
      Padding = new Padding(18, 20, 18, 16),
    };
    var heading = CreateLabel("预览与应用", 15f, FontStyle.Bold, TextPrimary);
    heading.Dock = DockStyle.Top;
    heading.Height = 40;
    panel.Controls.Add(heading);

    var previewSurface = new Panel
    {
      Dock = DockStyle.Top,
      Height = 244,
      BackColor = Color.Black,
      Padding = new Padding(1),
    };
    _previewImage.Dock = DockStyle.Fill;
    _previewImage.BackColor = Color.Black;
    _previewImage.SizeMode = PictureBoxSizeMode.Zoom;
    _previewImage.AccessibleName = "壁纸静态预览";
    previewSurface.Controls.Add(_previewImage);

    _mediaElement.LoadedBehavior = WpfMediaState.Manual;
    _mediaElement.UnloadedBehavior = WpfMediaState.Stop;
    _mediaElement.Stretch = WpfStretch.Uniform;
    _mediaElement.Volume = 0;
    _mediaElement.MediaEnded += (_, _) =>
    {
      _mediaElement.Position = TimeSpan.Zero;
      _mediaElement.Play();
    };
    _mediaElement.MediaFailed += (_, args) => BeginInvoke(() =>
      ShowMessage($"视频预览不可用：{args.ErrorException?.Message ?? "当前系统解码器不支持"}", true));
    _videoHost.Child = _mediaElement;
    _videoHost.Dock = DockStyle.Fill;
    _videoHost.BackColor = Color.Black;
    _videoHost.Visible = false;
    _videoHost.AccessibleName = "动态壁纸预览";
    previewSurface.Controls.Add(_videoHost);

    panel.Controls.Add(previewSurface);
    panel.Controls.SetChildIndex(previewSurface, 0);

    _selectionTitle.Dock = DockStyle.Top;
    _selectionTitle.Height = 56;
    _selectionTitle.Padding = new Padding(0, 14, 0, 0);
    _selectionTitle.Font = new Font(Font.FontFamily, 12f, FontStyle.Bold);
    _selectionTitle.ForeColor = TextPrimary;
    _selectionTitle.Text = "请选择一张壁纸";
    _selectionTitle.AutoEllipsis = true;
    panel.Controls.Add(_selectionTitle);
    panel.Controls.SetChildIndex(_selectionTitle, 0);

    _selectionMeta.Dock = DockStyle.Top;
    _selectionMeta.Height = 48;
    _selectionMeta.ForeColor = TextMuted;
    _selectionMeta.AutoEllipsis = true;
    _selectionMeta.Text = "支持 PNG、JPEG、WebP、MP4、WebM";
    panel.Controls.Add(_selectionMeta);
    panel.Controls.SetChildIndex(_selectionMeta, 0);

    ConfigureButton(_applyButton, "应用到 Codex", true);
    _applyButton.Dock = DockStyle.Top;
    _applyButton.Height = 44;
    _applyButton.Enabled = false;
    _applyButton.Click += async (_, _) => await ApplySelectedAsync();
    panel.Controls.Add(_applyButton);
    panel.Controls.SetChildIndex(_applyButton, 0);

    var revealHeading = CreateLabel("主题透明度 · 壁纸浓度", 10f, FontStyle.Bold, TextMuted);
    revealHeading.Dock = DockStyle.Top;
    revealHeading.Height = 44;
    revealHeading.Padding = new Padding(0, 18, 0, 0);
    panel.Controls.Add(revealHeading);
    panel.Controls.SetChildIndex(revealHeading, 0);

    _revealLabel.Dock = DockStyle.Top;
    _revealLabel.Height = 28;
    _revealLabel.ForeColor = TextPrimary;
    _revealLabel.AutoEllipsis = true;
    _revealLabel.Text = "100% · 完全透明（原始壁纸）";
    panel.Controls.Add(_revealLabel);
    panel.Controls.SetChildIndex(_revealLabel, 0);

    _revealSlider.Dock = DockStyle.Top;
    _revealSlider.Height = 42;
    _revealSlider.Minimum = 0;
    _revealSlider.Maximum = 100;
    _revealSlider.Value = 100;
    _revealSlider.TickFrequency = 10;
    _revealSlider.SmallChange = 5;
    _revealSlider.LargeChange = 10;
    _revealSlider.AccessibleName = "主题透明度，壁纸浓度：零为壁纸不透出，一百为完全显示原始壁纸";
    _revealSlider.Scroll += (_, _) => UpdateRevealLabel();
    _revealSlider.MouseUp += async (_, _) => await CommitRevealAsync();
    _revealSlider.KeyUp += async (_, _) => await CommitRevealAsync();
    panel.Controls.Add(_revealSlider);
    panel.Controls.SetChildIndex(_revealSlider, 0);

    var panelHeading = CreateLabel("面板透明度 · 界面磨玻璃", 10f, FontStyle.Bold, TextMuted);
    panelHeading.Dock = DockStyle.Top;
    panelHeading.Height = 44;
    panelHeading.Padding = new Padding(0, 18, 0, 0);
    panel.Controls.Add(panelHeading);
    panel.Controls.SetChildIndex(panelHeading, 0);

    _panelLabel.Dock = DockStyle.Top;
    _panelLabel.Height = 28;
    _panelLabel.ForeColor = TextPrimary;
    _panelLabel.AutoEllipsis = true;
    _panelLabel.Text = "未自定义 · 默认磨玻璃";
    panel.Controls.Add(_panelLabel);
    panel.Controls.SetChildIndex(_panelLabel, 0);

    _panelSlider.Dock = DockStyle.Top;
    _panelSlider.Height = 42;
    _panelSlider.Minimum = 0;
    _panelSlider.Maximum = 100;
    _panelSlider.Value = 30;
    _panelSlider.TickFrequency = 10;
    _panelSlider.SmallChange = 5;
    _panelSlider.LargeChange = 10;
    _panelSlider.AccessibleName = "面板透明度，界面磨玻璃浓度：零为面板最实，一百为面板最透";
    _panelSlider.Scroll += (_, _) => UpdatePanelLabel();
    _panelSlider.MouseUp += async (_, _) => await CommitPanelTransparencyAsync();
    _panelSlider.KeyUp += async (_, _) => await CommitPanelTransparencyAsync();
    panel.Controls.Add(_panelSlider);
    panel.Controls.SetChildIndex(_panelSlider, 0);

    _messageLabel.Dock = DockStyle.Bottom;
    _messageLabel.Height = 50;
    _messageLabel.ForeColor = TextMuted;
    _messageLabel.TextAlign = ContentAlignment.MiddleLeft;
    _messageLabel.AutoEllipsis = true;
    _messageLabel.Text = "选择壁纸后可直接应用。";
    _toolTip.SetToolTip(_messageLabel, _messageLabel.Text);
    panel.Controls.Add(_messageLabel);
    EnableDoubleBuffering(panel);
    return panel;
  }

  private async Task ReloadLibraryAsync()
  {
    _libraryLoad?.Cancel();
    _libraryLoad?.Dispose();
    _libraryLoad = CancellationTokenSource.CreateLinkedTokenSource(_lifetime.Token);
    var token = _libraryLoad.Token;
    _librarySummary.Text = "正在读取壁纸库…";
    try
    {
      var libraryItems = await _catalog.LoadAsync(_settings.LibraryPath, _searchBox.Text, token);
      token.ThrowIfCancellationRequested();
      var importedItems = WallpaperEngineReferenceCatalog.ResolveAndPrune(
        _settings.WallpaperEngineImports,
        _searchBox.Text,
        out var importsChanged);
      if (importsChanged)
      {
        _settingsStore.Save(_settings);
      }
      var items = libraryItems
        .Concat(importedItems)
        .GroupBy(item => item.Path, StringComparer.OrdinalIgnoreCase)
        .Select(group => group.First())
        .OrderByDescending(item => item.LastWriteTime)
        .ThenBy(item => item.Name, StringComparer.CurrentCultureIgnoreCase)
        .Take(500)
        .ToArray();
      ClearLibraryCards();
      _librarySummary.Text = items.Length == 0
        ? "暂无壁纸 · 点击左侧「添加壁纸」导入"
        : $"共 {items.Length} 个可直接使用的壁纸";

      foreach (var item in items)
      {
        token.ThrowIfCancellationRequested();
        var card = CreateWallpaperCard(item);
        _libraryFlow.Controls.Add(card);
      }
      LayoutLibraryCards();

      _ = LoadCardThumbnailsAsync(items, token);
    }
    catch (OperationCanceledException)
    {
      // A newer search or folder selection owns the next render.
    }
    catch (Exception exception)
    {
      _librarySummary.Text = "读取壁纸库失败";
      ShowError(exception);
    }
  }

  private async Task LoadCardThumbnailsAsync(
    IReadOnlyList<WallpaperItem> items,
    CancellationToken token)
  {
    var cardMap = _libraryFlow.Controls
      .OfType<Panel>()
      .Where(control => control.Tag is WallpaperItem)
      .ToDictionary(control => ((WallpaperItem)control.Tag!).Path, StringComparer.OrdinalIgnoreCase);

    foreach (var item in items)
    {
      token.ThrowIfCancellationRequested();
      var displayPath = WallpaperEngineReferenceCatalog.GetPreviewPath(item);
      var scale = _libraryFlow.DeviceDpi / 96f;
      var thumbnail = await Task.Run(
        () => ShellThumbnail.Get(displayPath, ScalePx(280, scale), ScalePx(170, scale)),
        token);
      if (thumbnail is null)
      {
        continue;
      }
      if (token.IsCancellationRequested || !cardMap.TryGetValue(item.Path, out var card) || card.IsDisposed)
      {
        thumbnail.Dispose();
        continue;
      }
      BeginInvoke(() =>
      {
        if (card.IsDisposed)
        {
          thumbnail.Dispose();
          return;
        }
        var image = card.Controls.OfType<PictureBox>().FirstOrDefault();
        if (image is not null)
        {
          image.Image?.Dispose();
          image.Image = thumbnail;
        }
      });
    }
  }

  private Panel CreateWallpaperCard(WallpaperItem item)
  {
    // Cards are created at runtime (after the form has scaled), so their pixel
    // constants must be scaled by the live DPI factor explicitly.
    var scale = DeviceDpi / 96f;
    var card = new Panel
    {
      Width = ScalePx(226, scale),
      Height = ScalePx(190, scale),
      Margin = new Padding(0, 0, ScalePx(14, scale), ScalePx(14, scale)),
      BackColor = Surface,
      Cursor = Cursors.Hand,
      Tag = item,
      AccessibleName = $"{item.Name}，{item.SourceLabel}",
    };
    var image = new PictureBox
    {
      Dock = DockStyle.Top,
      Height = ScalePx(126, scale),
      BackColor = Color.FromArgb(9, 10, 13),
      SizeMode = PictureBoxSizeMode.Zoom,
      Cursor = Cursors.Hand,
    };
    card.Controls.Add(image);
    var title = CreateLabel(item.Name, 9.5f, FontStyle.Bold, TextPrimary);
    title.Location = new Point(ScalePx(10, scale), ScalePx(136, scale));
    title.Size = new Size(ScalePx(204, scale), ScalePx(22, scale));
    title.AutoEllipsis = true;
    title.Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Right;
    title.Cursor = Cursors.Hand;
    _toolTip.SetToolTip(title, item.Name);
    card.Controls.Add(title);
    var metaText = $"{item.SourceLabel} · {item.SizeLabel}";
    var meta = CreateLabel(metaText, 8.5f, FontStyle.Regular, TextMuted);
    meta.Location = new Point(ScalePx(10, scale), ScalePx(162, scale));
    meta.Size = new Size(ScalePx(204, scale), ScalePx(20, scale));
    meta.AutoEllipsis = true;
    meta.Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Right;
    meta.Cursor = Cursors.Hand;
    _toolTip.SetToolTip(meta, metaText);
    card.Controls.Add(meta);
    EnableDoubleBuffering(card);

    void SelectCard(object? _, EventArgs __) => SelectWallpaper(item, card);
    card.Click += SelectCard;
    image.Click += SelectCard;
    title.Click += SelectCard;
    meta.Click += SelectCard;
    foreach (Control control in new Control[] { card, image, title, meta })
    {
      control.MouseEnter += (_, _) =>
      {
        if (card != _selectedCard)
        {
          card.BackColor = SurfaceHover;
        }
      };
      control.MouseLeave += (_, _) =>
      {
        if (card != _selectedCard)
        {
          card.BackColor = Surface;
        }
      };
    }
    return card;
  }

  private void SelectWallpaper(WallpaperItem item, Control card)
  {
    if (_selectedCard is not null && !_selectedCard.IsDisposed)
    {
      _selectedCard.BackColor = Surface;
    }
    _selectedWallpaper = item;
    _selectedCard = card;
    card.BackColor = Color.FromArgb(67, 43, 52);
    _selectionTitle.Text = item.Name;
    _selectionMeta.Text = $"{item.SourceLabel} · {item.Extension} · {item.SizeLabel}";
    _toolTip.SetToolTip(_selectionTitle, item.Name);
    _toolTip.SetToolTip(_selectionMeta, _selectionMeta.Text);
    _applyButton.Enabled = !_busy;
    ShowPreview(item);
  }

  private void ShowPreview(WallpaperItem item)
  {
    StopVideoPreview();
    _previewImage.Image?.Dispose();
    _previewImage.Image = null;
    if (item.Kind == WallpaperKind.Video)
    {
      _previewImage.Visible = false;
      _videoHost.Visible = true;
      _mediaElement.Source = new Uri(item.Path);
      _mediaElement.Position = TimeSpan.Zero;
      _mediaElement.Play();
    }
    else
    {
      _videoHost.Visible = false;
      _previewImage.Visible = true;
      var scale = DeviceDpi / 96f;
      _previewImage.Image = ShellThumbnail.Get(
        WallpaperEngineReferenceCatalog.GetPreviewPath(item),
        ScalePx(720, scale),
        ScalePx(480, scale));
    }
  }

  private void StopVideoPreview()
  {
    try
    {
      _mediaElement.Stop();
      _mediaElement.Source = null;
    }
    catch
    {
      // The WPF media host may already be tearing down with the form.
    }
  }

  private async Task ApplySelectedAsync()
  {
    if (_selectedWallpaper is null)
    {
      return;
    }
    var item = _selectedWallpaper;
    string? previewFallbackMessage = null;
    await RunOperationAsync(
      $"正在应用 {item.Name}…",
      async () =>
      {
        try
        {
          if (item.Source == WallpaperSource.WallpaperEngine)
          {
            await _service.ApplyWallpaperEngineAsync(item.Path, _lifetime.Token);
          }
          else
          {
            await _service.ApplyWallpaperAsync(item.Path, _lifetime.Token);
          }
        }
        catch (Exception exception) when (
          item.Source == WallpaperSource.WallpaperEngine &&
          item.Kind == WallpaperKind.Scene &&
          exception is not OperationCanceledException)
        {
          await _service.ApplyWallpaperEngineSceneFallbackAsync(item.Path, exception, _lifetime.Token);
          previewFallbackMessage = $"{exception.Message} 已回退应用该场景的静态预览图。";
        }
      },
      $"已应用：{item.Name}");
    if (previewFallbackMessage is not null)
    {
      MessageBox.Show(
        this,
        previewFallbackMessage,
        DisplayName,
        MessageBoxButtons.OK,
        MessageBoxIcon.Warning);
    }
    StopVideoPreview();
    _videoHost.Visible = false;
  }

  private async Task CommitRevealAsync()
  {
    var value = _revealSlider.Value;
    await RunOperationAsync(
      $"正在设置主题透明度 {value}%…",
      () => _service.SetRevealAsync(value, _lifetime.Token),
      value switch
      {
        0 => "主题已完全不透明。",
        100 => "主题已完全透明，正在显示原始壁纸画面。",
        _ => $"主题透明度已设为 {value}%。"
      },
      refreshLibrary: false);
  }

  private async Task CommitPanelTransparencyAsync()
  {
    var value = _panelSlider.Value;
    await RunOperationAsync(
      $"正在设置面板透明度 {value}%…",
      () => _service.SetPanelTransparencyAsync(value, _lifetime.Token),
      value switch
      {
        0 => "面板已调成最实（磨玻璃最浓）。",
        100 => "面板已调成最透（磨玻璃最淡）。",
        _ => $"面板透明度已设为 {value}%。"
      },
      refreshLibrary: false);
  }

  private async Task RestoreAsync()
  {
    var answer = MessageBox.Show(
      "这会停止动态壁纸并恢复 Codex 官方外观。Codex 可能需要重启一次。是否继续？",
      "恢复官方外观",
      MessageBoxButtons.YesNo,
      MessageBoxIcon.Warning,
      MessageBoxDefaultButton.Button2);
    if (answer != DialogResult.Yes)
    {
      return;
    }

    await RunOperationAsync(
      "正在恢复 Codex 官方外观…",
      () => _service.RestoreAsync(_lifetime.Token),
      "已恢复 Codex 官方外观。",
      refreshLibrary: false);
  }

  private void ShowSavedThemes()
  {
    using var dialog = new SavedThemesDialog(_service, _lifetime.Token);
    dialog.ShowDialog(this);
    if (dialog.LastAppliedTheme is not null)
    {
      ShowMessage($"已应用：{dialog.LastAppliedTheme.Name}", false);
      RefreshStatus();
    }
  }

  private async Task ShowWallpaperEngineAsync()
  {
    using var dialog = new WallpaperEngineDialog(_service, _lifetime.Token);
    if (dialog.ShowDialog(this) == DialogResult.OK && dialog.ImportedItems.Count > 0)
    {
      var added = WallpaperEngineReferenceCatalog.AddImports(
        _settings.WallpaperEngineImports,
        dialog.ImportedItems);
      if (added > 0)
      {
        _settingsStore.Save(_settings);
      }
      await ReloadLibraryAsync();
      ShowMessage(
        added == 0 ? "所选 Wallpaper Engine 视频已在主页中。" : $"已导入主页：{added} 个 Wallpaper Engine 视频。",
        false);
    }
  }

  private async Task ImportWallpapersAsync()
  {
    using var dialog = new OpenFileDialog
    {
      Title = "添加壁纸",
      Filter = "支持的壁纸|*.png;*.jpg;*.jpeg;*.webp;*.mp4;*.webm|" +
        "图片壁纸|*.png;*.jpg;*.jpeg;*.webp|动态壁纸|*.mp4;*.webm",
      InitialDirectory = _settings.LibraryPath,
      Multiselect = true,
      CheckFileExists = true,
      RestoreDirectory = true,
    };
    if (dialog.ShowDialog(this) != DialogResult.OK)
    {
      return;
    }

    SetBusy(true);
    ShowMessage($"正在添加 {dialog.FileNames.Length} 个壁纸…", false);
    try
    {
      Directory.CreateDirectory(_settings.LibraryPath);
      var added = 0;
      foreach (var source in dialog.FileNames)
      {
        _lifetime.Token.ThrowIfCancellationRequested();
        var sourcePath = Path.GetFullPath(source);
        if (!WallpaperCatalog.IsSupported(sourcePath))
        {
          throw new InvalidOperationException(
            $"不支持的壁纸格式：{Path.GetFileName(sourcePath)}");
        }
        if ((File.GetAttributes(sourcePath) & FileAttributes.ReparsePoint) != 0)
        {
          throw new InvalidOperationException(
            $"壁纸不能是符号链接或重解析点：{Path.GetFileName(sourcePath)}");
        }
        if (IsInsideDirectory(sourcePath, _settings.LibraryPath))
        {
          continue;
        }

        var destination = GetAvailableDestination(
          _settings.LibraryPath,
          Path.GetFileName(sourcePath));
        await using var input = new FileStream(
          sourcePath,
          FileMode.Open,
          FileAccess.Read,
          FileShare.Read,
          1024 * 1024,
          FileOptions.Asynchronous | FileOptions.SequentialScan);
        await using var output = new FileStream(
          destination,
          FileMode.CreateNew,
          FileAccess.Write,
          FileShare.None,
          1024 * 1024,
          FileOptions.Asynchronous | FileOptions.SequentialScan);
        await input.CopyToAsync(output, _lifetime.Token);
        await output.FlushAsync(_lifetime.Token);
        added++;
      }

      await ReloadLibraryAsync();
      ShowMessage(
        added == 0 ? "所选壁纸已在当前壁纸库中。" : $"已添加 {added} 个壁纸。",
        false);
    }
    catch (OperationCanceledException) when (_lifetime.IsCancellationRequested)
    {
      // App shutdown owns cancellation.
    }
    catch (Exception exception)
    {
      await ReloadLibraryAsync();
      ShowError(exception);
    }
    finally
    {
      SetBusy(false);
    }
  }

  private async Task ChooseLibraryAsync()
  {
    using var dialog = new FolderBrowserDialog
    {
      Description = "选择 Codex 壁纸库文件夹",
      SelectedPath = _settings.LibraryPath,
      ShowNewFolderButton = true,
      UseDescriptionForTitle = true,
    };
    if (dialog.ShowDialog(this) != DialogResult.OK)
    {
      return;
    }
    _settings.LibraryPath = Path.GetFullPath(dialog.SelectedPath);
    _settingsStore.Save(_settings);
    _libraryPathLabel.Text = CompactPath(_settings.LibraryPath);
    _toolTip.SetToolTip(_libraryPathLabel, _settings.LibraryPath);
    await ReloadLibraryAsync();
  }

  private void OpenLibraryFolder()
  {
    Directory.CreateDirectory(_settings.LibraryPath);
    Process.Start(new ProcessStartInfo
    {
      FileName = "explorer.exe",
      UseShellExecute = true,
      ArgumentList = { _settings.LibraryPath },
    });
  }

  private async Task RunOperationAsync(
    string progress,
    Func<Task> operation,
    string success,
    bool refreshLibrary = false)
  {
    if (_busy)
    {
      return;
    }
    SetBusy(true);
    ShowMessage(progress, false);
    try
    {
      await operation();
      ShowMessage(success, false);
      RefreshStatus();
      if (refreshLibrary)
      {
        await ReloadLibraryAsync();
      }
    }
    catch (OperationCanceledException) when (_lifetime.IsCancellationRequested)
    {
      // App shutdown owns cancellation.
    }
    catch (OperationCanceledException exception)
    {
      ShowMessage(exception.Message, false);
    }
    catch (Exception exception)
    {
      ShowError(exception);
    }
    finally
    {
      SetBusy(false);
    }
  }

  private bool ConfirmCodexRestart(string message) =>
    MessageBox.Show(
      this,
      message,
      DisplayName,
      MessageBoxButtons.YesNo,
      MessageBoxIcon.Warning,
      MessageBoxDefaultButton.Button2) == DialogResult.Yes;

  private void RefreshStatus()
  {
    var status = _service.GetStatus();
    _pauseRequested = status.Paused;
    _statusLabel.Text = $"{status.Summary}\r\n当前壁纸：{status.CurrentWallpaperLabel}";
    _toolTip.SetToolTip(_statusLabel, $"{status.Summary}；当前壁纸：{status.CurrentWallpaperLabel}");
    _statusDot.BackColor = status.Paused
      ? Warning
      : status.WatcherRunning
        ? Success
        : status.CodexRunning
          ? Accent
          : Warning;
    _pauseButton.Text = status.Paused ? "恢复皮肤" : "暂停皮肤";
    _pauseButton.Enabled = !_busy && (status.WatcherRunning || status.Paused);
    if (!_revealSlider.Focused)
    {
      _revealSlider.Value = Math.Clamp(status.RevealPercent, 0, 100);
      UpdateRevealLabel();
    }
    if (!_panelSlider.Focused)
    {
      // A theme with no stored preference must not have its slider snapped back
      // to the default. status.PanelTransparencyPercent is null both before the
      // user touches the slider and right after a theme switch, so the old
      // "?? 30" reset undid every drag: the value returned to 30, which renders
      // at exactly the same alpha as the unset fallback, so the slider looked
      // dead. Only mirror a real stored value and otherwise leave the knob be.
      if (status.PanelTransparencyPercent is int storedPanelPercent)
      {
        _panelSlider.Value = Math.Clamp(storedPanelPercent, 0, 100);
      }
      UpdatePanelLabel(status.PanelTransparencyPercent is null);
    }
    _trayIcon.Text = $"{DisplayName} · {status.Summary}";
  }

  private void UpdateRevealLabel()
  {
    _revealLabel.Text = _revealSlider.Value switch
    {
      0 => "0% · 完全不透明",
      100 => "100% · 完全透明（原始壁纸）",
      var value => $"{value}% · 壁纸逐步透出"
    };
    _toolTip.SetToolTip(_revealLabel, _revealLabel.Text);
  }

  private void UpdatePanelLabel(bool usingDefault = false)
  {
    _panelLabel.Text = usingDefault ? "未自定义 · 默认磨玻璃" : _panelSlider.Value switch
    {
      0 => "0% · 面板最实（磨玻璃最浓）",
      100 => "100% · 面板最透（磨玻璃最淡）",
      var value => $"{value}% · 界面磨玻璃浓度"
    };
    _toolTip.SetToolTip(_panelLabel, _panelLabel.Text);
  }

  private void SetBusy(bool busy)
  {
    _busy = busy;
    _startButton.Enabled = !busy;
    _importButton.Enabled = !busy;
    _restoreButton.Enabled = !busy;
    _themesButton.Enabled = !busy;
    _wallpaperEngineButton.Enabled = !busy;
    _applyButton.Enabled = !busy && _selectedWallpaper is not null;
    _revealSlider.Enabled = !busy;
    _panelSlider.Enabled = !busy;
    _searchBox.Enabled = !busy;
    UseWaitCursor = busy;
  }

  private void ShowMessage(string message, bool error)
  {
    _messageLabel.Text = message;
    _messageLabel.ForeColor = error ? Color.FromArgb(246, 128, 128) : TextMuted;
    _toolTip.SetToolTip(_messageLabel, message);
  }

  private void ShowError(Exception exception)
  {
    ShowMessage(exception.Message, true);
    MessageBox.Show(
      exception.Message,
      DisplayName,
      MessageBoxButtons.OK,
      MessageBoxIcon.Error);
  }

  private NotifyIcon BuildTrayIcon()
  {
    var menu = new ContextMenuStrip
    {
      BackColor = SurfaceRaised,
      ForeColor = TextPrimary,
      Renderer = new ToolStripProfessionalRenderer(new DarkColorTable()),
    };
    menu.Items.Add("打开壁纸管理器", null, (_, _) => ShowManager());
    menu.Items.Add("启动 / 重新应用", null, async (_, _) => await RunOperationAsync(
      "正在启动 Codex 动态壁纸…",
      () => _service.StartAsync(_lifetime.Token),
      "Codex 动态壁纸已启动。"));
    menu.Items.Add("暂停 / 恢复", null, async (_, _) =>
    {
      var status = _service.GetStatus();
      await RunOperationAsync(
        status.Paused ? "正在恢复皮肤…" : "正在暂停皮肤…",
        () => _service.SetPausedAsync(!status.Paused, _lifetime.Token),
        status.Paused ? "皮肤已恢复。" : "皮肤已暂停。");
    });
    menu.Items.Add(new ToolStripSeparator());
    menu.Items.Add("退出管理器", null, (_, _) =>
    {
      _allowExit = true;
      Application.Exit();
    });
    var tray = new NotifyIcon
    {
      Icon = _appIcon,
      Text = DisplayName,
      Visible = true,
      ContextMenuStrip = menu,
    };
    tray.DoubleClick += (_, _) => ShowManager();
    return tray;
  }

  private void ShowManager()
  {
    Show();
    WindowState = FormWindowState.Normal;
    Activate();
    BringToFront();
  }

  private void OnFormClosing(object? sender, FormClosingEventArgs args)
  {
    if (_allowExit || args.CloseReason == CloseReason.WindowsShutDown)
    {
      return;
    }
    args.Cancel = true;
    StopVideoPreview();
    _videoHost.Visible = false;
    Hide();
    _trayIcon.ShowBalloonTip(
      1800,
      DisplayName,
      "管理器仍在任务栏托盘运行。",
      ToolTipIcon.Info);
  }

  private void ClearLibraryCards()
  {
    StopVideoPreview();
    _selectedWallpaper = null;
    _selectedCard = null;
    _applyButton.Enabled = false;
    _selectionTitle.Text = "请选择一张壁纸";
    _selectionMeta.Text = "支持 PNG、JPEG、WebP、MP4、WebM";
    _toolTip.SetToolTip(_selectionTitle, null);
    _toolTip.SetToolTip(_selectionMeta, null);
    _previewImage.Image?.Dispose();
    _previewImage.Image = null;
    foreach (Control control in _libraryFlow.Controls)
    {
      foreach (var image in control.Controls.OfType<PictureBox>())
      {
        image.Image?.Dispose();
      }
      control.Dispose();
    }
    _libraryFlow.Controls.Clear();
  }

  /// <summary>
  ///  Reflows the wallpaper grid: the column count adapts to the available
  ///  width using the design-width card (210px at 96 DPI) as the minimum
  ///  threshold, and every row then divides the width equally so no dead
  ///  space is left on the right edge.
  /// </summary>
  private void LayoutLibraryCards()
  {
    if (_libraryFlow.Controls.Count == 0)
    {
      return;
    }
    var scale = _libraryFlow.DeviceDpi / 96f;
    var gap = ScalePx(14, scale);
    var minCardWidth = ScalePx(210, scale);
    var available = _libraryFlow.ClientSize.Width - _libraryFlow.Padding.Horizontal;
    if (available < minCardWidth)
    {
      available = minCardWidth;
    }
    var columns = Math.Max(1, (available + gap) / (minCardWidth + gap));
    var cardWidth = (available - gap * (columns - 1)) / columns;
    if (cardWidth < minCardWidth)
    {
      columns = 1;
      cardWidth = available;
    }
    if (cardWidth <= 0)
    {
      return;
    }
    foreach (Control card in _libraryFlow.Controls)
    {
      card.Width = cardWidth;
    }
  }

  private static int ScalePx(int value, float scale) => (int)MathF.Round(value * scale);

  private static void EnableDoubleBuffering(Control control)
  {
    typeof(Control)
      .GetProperty("DoubleBuffered", BindingFlags.Instance | BindingFlags.NonPublic)
      ?.SetValue(control, true);
  }

  private static void ConfigureButton(Button button, string text, bool primary, bool danger = false)
  {
    button.Text = text;
    button.FlatStyle = FlatStyle.Flat;
    button.FlatAppearance.BorderSize = primary ? 0 : 1;
    button.FlatAppearance.BorderColor = danger
      ? Color.FromArgb(122, 65, 76)
      : Color.FromArgb(70, 75, 88);
    button.BackColor = primary
      ? Accent
      : danger
        ? Color.FromArgb(64, 37, 43)
        : SurfaceRaised;
    button.ForeColor = primary ? Color.White : danger ? Color.FromArgb(255, 178, 190) : TextPrimary;
    button.Cursor = Cursors.Hand;
    button.TextAlign = ContentAlignment.MiddleCenter;
    button.FlatAppearance.MouseOverBackColor = primary
      ? AccentHover
      : danger
        ? Color.FromArgb(83, 44, 52)
        : SurfaceHover;
  }

  private static Label CreateLabel(string text, float size, FontStyle style, Color color) => new()
  {
    Text = text,
    Font = new Font("Segoe UI Variable Text", size, style, GraphicsUnit.Point),
    ForeColor = color,
    BackColor = Color.Transparent,
  };

  private static string CompactPath(string path)
  {
    var desktop = Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory);
    return path.StartsWith(desktop, StringComparison.OrdinalIgnoreCase)
      ? "桌面" + path[desktop.Length..]
      : path;
  }

  private static bool IsInsideDirectory(string path, string directory)
  {
    var relative = Path.GetRelativePath(Path.GetFullPath(directory), Path.GetFullPath(path));
    return !Path.IsPathRooted(relative) &&
      !relative.Equals("..", StringComparison.Ordinal) &&
      !relative.StartsWith(".." + Path.DirectorySeparatorChar, StringComparison.Ordinal);
  }

  private static string GetAvailableDestination(string directory, string fileName)
  {
    var destination = Path.Combine(directory, fileName);
    if (!File.Exists(destination))
    {
      return destination;
    }

    var stem = Path.GetFileNameWithoutExtension(fileName);
    var extension = Path.GetExtension(fileName);
    for (var index = 2; index < 10_000; index++)
    {
      destination = Path.Combine(directory, $"{stem} ({index}){extension}");
      if (!File.Exists(destination))
      {
        return destination;
      }
    }
    throw new IOException($"无法为壁纸生成可用文件名：{fileName}");
  }

  private static Icon CreateAppIcon()
  {
    using var bitmap = new Bitmap(64, 64);
    using var graphics = Graphics.FromImage(bitmap);
    graphics.SmoothingMode = SmoothingMode.AntiAlias;
    graphics.Clear(Color.FromArgb(20, 22, 28));
    using var brush = new LinearGradientBrush(
      new Rectangle(8, 8, 48, 48),
      Color.FromArgb(242, 112, 145),
      Color.FromArgb(126, 91, 220),
      45f);
    graphics.FillEllipse(brush, 8, 8, 48, 48);
    using var cutout = new SolidBrush(Color.FromArgb(20, 22, 28));
    graphics.FillEllipse(cutout, 24, 9, 34, 34);
    using var star = new SolidBrush(Color.White);
    graphics.FillEllipse(star, 39, 38, 5, 5);
    graphics.FillEllipse(star, 28, 45, 3, 3);
    var handle = bitmap.GetHicon();
    try
    {
      using var source = Icon.FromHandle(handle);
      return (Icon)source.Clone();
    }
    finally
    {
      DestroyIcon(handle);
    }
  }

  private static void SetDarkTitleBar(IntPtr handle)
  {
    if (!OperatingSystem.IsWindowsVersionAtLeast(10, 0, 17763))
    {
      return;
    }
    var enabled = 1;
    DwmSetWindowAttribute(handle, 20, ref enabled, sizeof(int));
  }

  [DllImport("dwmapi.dll")]
  private static extern int DwmSetWindowAttribute(
    IntPtr window,
    int attribute,
    ref int value,
    int valueSize);

  [DllImport("user32.dll")]
  [return: MarshalAs(UnmanagedType.Bool)]
  private static extern bool DestroyIcon(IntPtr icon);

  private sealed class DarkColorTable : ProfessionalColorTable
  {
    public override Color ToolStripDropDownBackground => SurfaceRaised;
    public override Color ImageMarginGradientBegin => SurfaceRaised;
    public override Color ImageMarginGradientMiddle => SurfaceRaised;
    public override Color ImageMarginGradientEnd => SurfaceRaised;
    public override Color MenuItemSelected => SurfaceHover;
    public override Color MenuItemBorder => SurfaceHover;
    public override Color SeparatorDark => Color.FromArgb(68, 72, 84);
    public override Color SeparatorLight => Color.FromArgb(68, 72, 84);
  }
}

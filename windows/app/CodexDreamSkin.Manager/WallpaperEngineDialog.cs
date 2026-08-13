namespace CodexDreamSkin.Manager;

internal sealed class WallpaperEngineDialog : Form
{
  private static readonly Color Canvas = Color.FromArgb(17, 19, 24);
  private static readonly Color Surface = Color.FromArgb(25, 28, 35);
  private static readonly Color SurfaceRaised = Color.FromArgb(34, 38, 47);
  private static readonly Color SurfaceHover = Color.FromArgb(44, 48, 58);
  private static readonly Color Accent = Color.FromArgb(225, 105, 131);
  private static readonly Color AccentHover = Color.FromArgb(240, 124, 149);
  private static readonly Color TextPrimary = Color.FromArgb(244, 240, 243);
  private static readonly Color TextMuted = Color.FromArgb(167, 170, 180);

  private readonly DreamSkinService _service;
  private readonly CancellationToken _cancellationToken;
  private readonly ListBox _items = new();
  private readonly Label _statusLabel = new();
  private readonly Button _importButton = new();
  private bool _busy;

  public WallpaperEngineDialog(DreamSkinService service, CancellationToken cancellationToken)
  {
    _service = service;
    _cancellationToken = cancellationToken;

    Text = "Wallpaper Engine 本地壁纸";
    StartPosition = FormStartPosition.CenterParent;
    FormBorderStyle = FormBorderStyle.FixedDialog;
    MaximizeBox = false;
    MinimizeBox = false;
    ShowInTaskbar = false;
    ClientSize = new Size(590, 440);
    BackColor = Canvas;
    ForeColor = TextPrimary;
    Font = new Font("Segoe UI Variable Text", 10f, FontStyle.Regular, GraphicsUnit.Point);

    BuildLayout();
    Shown += async (_, _) => await ReloadItemsAsync();
  }

  public IReadOnlyList<WallpaperEngineItem> ImportedItems { get; private set; } = Array.Empty<WallpaperEngineItem>();

  private void BuildLayout()
  {
    var layout = new TableLayoutPanel
    {
      Dock = DockStyle.Fill,
      ColumnCount = 1,
      RowCount = 5,
      Padding = new Padding(20),
      BackColor = Canvas,
    };
    layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 38));
    layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 42));
    layout.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
    layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 34));
    layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 46));

    var heading = new Label
    {
      Dock = DockStyle.Fill,
      Text = "Wallpaper Engine 已下载壁纸",
      Font = new Font(Font.FontFamily, 14f, FontStyle.Bold),
      ForeColor = TextPrimary,
      TextAlign = ContentAlignment.MiddleLeft,
    };
    layout.Controls.Add(heading, 0, 0);

    var hint = new Label
    {
      Dock = DockStyle.Fill,
      Text = "视频和 Scene 场景各显示一次；Scene 由独立本地渲染侧车播放，Web 暂不支持。",
      ForeColor = TextMuted,
      AutoEllipsis = true,
      TextAlign = ContentAlignment.MiddleLeft,
    };
    layout.Controls.Add(hint, 0, 1);

    _items.Dock = DockStyle.Fill;
    _items.BorderStyle = BorderStyle.FixedSingle;
    _items.BackColor = Surface;
    _items.ForeColor = TextPrimary;
    _items.IntegralHeight = false;
    _items.SelectionMode = SelectionMode.MultiExtended;
    _items.AccessibleName = "Wallpaper Engine 本地壁纸列表";
    _items.AccessibleDescription = "选择已下载的视频或场景壁纸后，将其导入 Codex 壁纸主页。";
    _items.SelectedIndexChanged += (_, _) => UpdateActionState();
    layout.Controls.Add(_items, 0, 2);

    _statusLabel.Dock = DockStyle.Fill;
    _statusLabel.ForeColor = TextMuted;
    _statusLabel.Text = "正在扫描本机 Steam 库…";
    _statusLabel.TextAlign = ContentAlignment.MiddleLeft;
    _statusLabel.AutoEllipsis = true;
    layout.Controls.Add(_statusLabel, 0, 3);

    var actions = new FlowLayoutPanel
    {
      Dock = DockStyle.Fill,
      FlowDirection = FlowDirection.RightToLeft,
      WrapContents = false,
      BackColor = Canvas,
      Padding = new Padding(0, 4, 0, 0),
    };
    var closeButton = new Button { DialogResult = DialogResult.Cancel, Width = 92, Height = 34 };
    ConfigureButton(closeButton, "关闭", false);
    closeButton.AccessibleName = "关闭 Wallpaper Engine 本地壁纸窗口";
    ConfigureButton(_importButton, "导入到主页", true);
    _importButton.Width = 112;
    _importButton.Height = 34;
    _importButton.AccessibleName = "将选中的 Wallpaper Engine 壁纸导入主页";
    _importButton.Click += (_, _) => ImportSelected();
    actions.Controls.Add(closeButton);
    actions.Controls.Add(_importButton);
    layout.Controls.Add(actions, 0, 4);

    CancelButton = closeButton;
    Controls.Add(layout);
    UpdateActionState();
  }

  private async Task ReloadItemsAsync()
  {
    SetBusy(true);
    _statusLabel.ForeColor = TextMuted;
    _statusLabel.Text = "正在扫描本机 Steam 库…";
    try
    {
      var items = await _service.ListWallpaperEngineAsync(_cancellationToken);
      if (IsDisposed)
      {
        return;
      }
      _items.BeginUpdate();
      try
      {
        _items.Items.Clear();
        foreach (var item in items)
        {
          _items.Items.Add(item);
        }
      }
      finally
      {
        _items.EndUpdate();
      }
      _statusLabel.Text = items.Count == 0
        ? "未找到兼容的视频或 Scene 场景。请先在 Wallpaper Engine 中完成订阅和下载。"
        : $"找到 {items.Count} 个兼容壁纸；每个 Workshop 项目仅显示一次。";
    }
    catch (OperationCanceledException)
    {
      _statusLabel.Text = "扫描已取消。";
    }
    catch (Exception exception)
    {
      ShowError(exception);
    }
    finally
    {
      if (!IsDisposed)
      {
        SetBusy(false);
      }
    }
  }

  private void ImportSelected()
  {
    var selected = _items.SelectedItems.Cast<WallpaperEngineItem>().ToArray();
    if (selected.Length == 0)
    {
      return;
    }
    ImportedItems = selected;
    DialogResult = DialogResult.OK;
    Close();
  }

  private void SetBusy(bool busy)
  {
    _busy = busy;
    _items.Enabled = !busy;
    UpdateActionState();
    UseWaitCursor = busy;
  }

  private void UpdateActionState()
  {
    _importButton.Enabled = !_busy && _items.SelectedItems.Count > 0;
  }

  private void ShowError(Exception exception)
  {
    _statusLabel.Text = exception.Message;
    _statusLabel.ForeColor = Color.FromArgb(246, 128, 128);
    MessageBox.Show(exception.Message, "Wallpaper Engine 本地壁纸", MessageBoxButtons.OK, MessageBoxIcon.Error);
  }

  private static void ConfigureButton(Button button, string text, bool primary)
  {
    button.Text = text;
    button.FlatStyle = FlatStyle.Flat;
    button.FlatAppearance.BorderSize = primary ? 0 : 1;
    button.FlatAppearance.BorderColor = Color.FromArgb(70, 75, 88);
    button.BackColor = primary ? Accent : SurfaceRaised;
    button.ForeColor = primary ? Color.White : TextPrimary;
    button.Cursor = Cursors.Hand;
    button.FlatAppearance.MouseOverBackColor = primary ? AccentHover : SurfaceHover;
  }
}

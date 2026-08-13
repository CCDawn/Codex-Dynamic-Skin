namespace CodexDreamSkin.Manager;

internal sealed class SavedThemesDialog : Form
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
  private readonly ListBox _themes = new();
  private readonly TextBox _nameBox = new();
  private readonly Label _statusLabel = new();
  private readonly Button _applyButton = new();
  private readonly Button _saveButton = new();
  private bool _busy;

  public SavedThemesDialog(DreamSkinService service, CancellationToken cancellationToken)
  {
    _service = service;
    _cancellationToken = cancellationToken;

    Text = "已保存主题";
    StartPosition = FormStartPosition.CenterParent;
    FormBorderStyle = FormBorderStyle.FixedDialog;
    MaximizeBox = false;
    MinimizeBox = false;
    ShowInTaskbar = false;
    ClientSize = new Size(520, 430);
    BackColor = Canvas;
    ForeColor = TextPrimary;
    Font = new Font("Segoe UI Variable Text", 10f, FontStyle.Regular, GraphicsUnit.Point);

    BuildLayout();
    Shown += async (_, _) => await ReloadThemesAsync();
  }

  public SavedTheme? LastAppliedTheme { get; private set; }

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
    layout.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
    layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 32));
    layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 62));
    layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 46));

    var heading = new Label
    {
      Dock = DockStyle.Fill,
      Text = "已保存主题",
      Font = new Font(Font.FontFamily, 14f, FontStyle.Bold),
      ForeColor = TextPrimary,
      TextAlign = ContentAlignment.MiddleLeft,
    };
    layout.Controls.Add(heading, 0, 0);

    _themes.Dock = DockStyle.Fill;
    _themes.BorderStyle = BorderStyle.FixedSingle;
    _themes.BackColor = Surface;
    _themes.ForeColor = TextPrimary;
    _themes.IntegralHeight = false;
    _themes.AccessibleName = "已保存主题列表";
    _themes.AccessibleDescription = "选择静态或动态主题后可应用到 Codex。";
    _themes.SelectedIndexChanged += (_, _) => UpdateActionState();
    layout.Controls.Add(_themes, 0, 1);

    _statusLabel.Dock = DockStyle.Fill;
    _statusLabel.ForeColor = TextMuted;
    _statusLabel.Text = "正在读取已保存主题…";
    _statusLabel.TextAlign = ContentAlignment.MiddleLeft;
    _statusLabel.AutoEllipsis = true;
    layout.Controls.Add(_statusLabel, 0, 2);

    var savePanel = new TableLayoutPanel
    {
      Dock = DockStyle.Fill,
      ColumnCount = 2,
      RowCount = 1,
      Margin = new Padding(0, 4, 0, 4),
    };
    savePanel.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
    savePanel.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 128));
    _nameBox.Dock = DockStyle.Fill;
    _nameBox.PlaceholderText = "输入名称以保存当前主题（最多 80 字符）";
    _nameBox.BackColor = SurfaceRaised;
    _nameBox.ForeColor = TextPrimary;
    _nameBox.BorderStyle = BorderStyle.FixedSingle;
    _nameBox.AccessibleName = "当前主题名称";
    _nameBox.TextChanged += (_, _) => UpdateActionState();
    savePanel.Controls.Add(_nameBox, 0, 0);
    ConfigureButton(_saveButton, "保存当前主题", false);
    _saveButton.Dock = DockStyle.Fill;
    _saveButton.AccessibleName = "保存当前主题";
    _saveButton.Click += async (_, _) => await SaveCurrentThemeAsync();
    savePanel.Controls.Add(_saveButton, 1, 0);
    layout.Controls.Add(savePanel, 0, 3);

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
    closeButton.AccessibleName = "关闭已保存主题窗口";
    ConfigureButton(_applyButton, "应用主题", true);
    _applyButton.Width = 112;
    _applyButton.Height = 34;
    _applyButton.AccessibleName = "应用选中的主题";
    _applyButton.Click += async (_, _) => await ApplySelectedThemeAsync();
    actions.Controls.Add(closeButton);
    actions.Controls.Add(_applyButton);
    layout.Controls.Add(actions, 0, 4);

    CancelButton = closeButton;
    Controls.Add(layout);
    UpdateActionState();
  }

  private async Task ReloadThemesAsync(string? selectedId = null)
  {
    SetBusy(true);
    _statusLabel.ForeColor = TextMuted;
    _statusLabel.Text = "正在读取已保存主题…";
    try
    {
      var themes = await _service.ListSavedThemesAsync(_cancellationToken);
      if (IsDisposed)
      {
        return;
      }
      _themes.BeginUpdate();
      try
      {
        _themes.Items.Clear();
        foreach (var theme in themes)
        {
          _themes.Items.Add(theme);
        }
        var selectedIndex = string.IsNullOrWhiteSpace(selectedId)
          ? -1
          : themes.ToList().FindIndex(theme => theme.Id.Equals(selectedId, StringComparison.Ordinal));
        if (selectedIndex >= 0)
        {
          _themes.SelectedIndex = selectedIndex;
        }
      }
      finally
      {
        _themes.EndUpdate();
      }
      _statusLabel.Text = themes.Count == 0
        ? "暂无已保存主题。"
        : $"共 {themes.Count} 个主题，支持静态和动态壁纸。";
    }
    catch (OperationCanceledException)
    {
      _statusLabel.Text = "读取已取消。";
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

  private async Task SaveCurrentThemeAsync()
  {
    var name = _nameBox.Text.Trim();
    if (name.Length == 0)
    {
      _nameBox.Focus();
      return;
    }
    SetBusy(true);
    _statusLabel.ForeColor = TextMuted;
    _statusLabel.Text = "正在保存当前主题…";
    try
    {
      var saved = await _service.SaveCurrentThemeAsync(name, _cancellationToken);
      _nameBox.Clear();
      await ReloadThemesAsync(saved.Id);
      if (!IsDisposed)
      {
        _statusLabel.Text = $"已保存：{saved.Name}";
      }
    }
    catch (OperationCanceledException)
    {
      _statusLabel.Text = "保存已取消。";
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

  private async Task ApplySelectedThemeAsync()
  {
    if (_themes.SelectedItem is not SavedTheme selectedTheme)
    {
      return;
    }
    SetBusy(true);
    _statusLabel.ForeColor = TextMuted;
    _statusLabel.Text = $"正在应用：{selectedTheme.Name}…";
    try
    {
      LastAppliedTheme = await _service.ApplySavedThemeAsync(selectedTheme.Id, _cancellationToken);
      _statusLabel.Text = $"已应用：{LastAppliedTheme.Name}";
    }
    catch (OperationCanceledException)
    {
      _statusLabel.Text = "应用已取消。";
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

  private void SetBusy(bool busy)
  {
    _busy = busy;
    _themes.Enabled = !busy;
    _nameBox.Enabled = !busy;
    UpdateActionState();
    UseWaitCursor = busy;
  }

  private void UpdateActionState()
  {
    _applyButton.Enabled = !_busy && _themes.SelectedItem is SavedTheme;
    _saveButton.Enabled = !_busy && !string.IsNullOrWhiteSpace(_nameBox.Text);
  }

  private void ShowError(Exception exception)
  {
    _statusLabel.Text = exception.Message;
    _statusLabel.ForeColor = Color.FromArgb(246, 128, 128);
    MessageBox.Show(exception.Message, "Codex 动态壁纸", MessageBoxButtons.OK, MessageBoxIcon.Error);
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

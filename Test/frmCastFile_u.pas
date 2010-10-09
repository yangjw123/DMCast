unit frmCastFile_u;

interface

uses
  Windows, Messages, SysUtils, Variants, Classes, Graphics, Controls, Forms,
  Dialogs, StdCtrls, XPMan, Buttons, ComCtrls, ExtCtrls, ImgList, WinSock,
  FuncLib, Config_u, IStats_u, Spin, ShellAPI;

type
  TSenderStats = class(TInterfacedObject, ISenderStats)
  private
    FBlockSize: Integer;
    FStartTime: DWORD;                  //���俪ʼʱ��
    FStatPeriod: DWORD;                 //״̬��ʾ����
    FPeriodStart: DWORD;                //���ڿ�ʼ����
    FLastPosBytes: Int64;               //���ͳ�ƽ���
    FTotalBytes: Int64;                 //��������
    FNrRetrans: Int64;                  //�ش���

    FTransState: TTransState;
  protected
    procedure DoDisplay();
  public
    constructor Create(blockSize: Integer; statPeriod: Integer);
    destructor Destroy; override;

    procedure TransStateChange(TransState: TTransState);

    procedure AddBytes(bytes: Integer);
    procedure AddRetrans(nrRetrans: Integer);

    function TransState: TTransState;
  end;

  TPartsStats = class(TInterfacedObject, IPartsStats)
  private
    FNrOnline: Integer;
  public
    function Add(index: Integer; addr: PSockAddrIn; sockBuf: Integer): Boolean;
    function Remove(index: Integer; addr: PSockAddrIn): Boolean;
    function GetNrOnline(): Integer;
  end;

  TFileReader = class(TThread)
  private
    FFile: TFileStream;
    FFifo: Pointer;
  protected
    procedure Execute; override;
  public
    constructor Create(fileName: string; lpFifo: Pointer);
    destructor Destroy; override;
    procedure Terminate; overload;
  end;

const
  WM_UPDATE_ONLINE  = WM_USER + 1;
  WM_AUTO_STOP      = WM_USER + 2;

type
  TfrmCastFile = class(TForm)
    dlgOpen1: TOpenDialog;
    XPManifest1: TXPManifest;
    stat1: TStatusBar;
    lvClient: TListView;
    Panel1: TPanel;
    Label1: TLabel;
    edtFile: TEdit;
    SpeedButton1: TSpeedButton;
    btnTrans: TButton;
    ImageList1: TImageList;
    btnStart: TButton;
    pnl1: TPanel;
    btnStop: TButton;
    grp1: TGroupBox;
    lbl1: TLabel;
    lbl2: TLabel;
    lbl3: TLabel;
    lbl4: TLabel;
    lblSliceSize: TLabel;
    lblRexmit: TLabel;
    lblSpeed: TLabel;
    lblTransBytes: TLabel;
    grp2: TGroupBox;
    chkAutoSliceSize: TCheckBox;
    lbl5: TLabel;
    seSliceSize: TSpinEdit;
    grp4: TGroupBox;
    lbl6: TLabel;
    seWaitReceivers: TSpinEdit;
    chkLoopStart: TCheckBox;
    chkStreamMode: TCheckBox;
    seRetriesUntilDrop: TSpinEdit;
    lbl7: TLabel;
    lbl8: TLabel;
    lbl9: TLabel;
    seMaxWait: TSpinEdit;
    lblFile: TLabel;
    lblFileSize: TLabel;
    pb1: TProgressBar;

    procedure btnStartClick(Sender: TObject);
    procedure SpeedButton1Click(Sender: TObject);
    procedure btnStopClick(Sender: TObject);
    procedure btnTransClick(Sender: TObject);
    procedure FormCreate(Sender: TObject);
    procedure lbl8Click(Sender: TObject);
  private
    FPartsStats: IPartsStats;
    FSenderStats: ISenderStats;

    FNego: Pointer;
    FFifo: Pointer;
    FFileReader: TFileReader;
    procedure UpdateOnline(var Msg: TMessage); message WM_UPDATE_ONLINE;
    procedure OnAutoStop(var Msg: TMessage); message WM_AUTO_STOP;
  public

  end;

var
  frmCastFile       : TfrmCastFile;
  dwThID            : DWORD;
  g_FileSize        : Int64;

implementation
//{$DEFINE IS_IMPORT_MODULE}
{$IFNDEF IS_IMPORT_MODULE}
uses
  DMCSender_u;
{$ELSE}
//API�ӿ�
const
  DMC_SENDER_DLL    = 'DMCSender.dll';

procedure DMCConfigFill(var config: TSendConfig); stdcall;
  external DMC_SENDER_DLL;

function DMCNegoCreate(config: PSendConfig; TransStats: ISenderStats;
  PartsStats: IPartsStats; var lpFifo: Pointer): Pointer; stdcall;
  external DMC_SENDER_DLL;

function DMCDataWriteWait(lpFifo: Pointer; var dwBytes: DWORD): Pointer; stdcall;
  external DMC_SENDER_DLL;

function DMCDataWrited(lpFifo: Pointer; dwBytes: DWORD): Boolean; stdcall;
  external DMC_SENDER_DLL;

function DMCDoTransfer(lpNego: Pointer): Boolean; stdcall;
  external DMC_SENDER_DLL;

function DMCNegoDestroy(lpNego: Pointer): Boolean; stdcall;
  external DMC_SENDER_DLL;
{$ENDIF}

{$R *.dfm}

{ TSenderStats }

constructor TSenderStats.Create(blockSize: Integer; statPeriod: Integer);
begin
  FBlockSize := blockSize;
  FStatPeriod := statPeriod;
end;

destructor TSenderStats.Destroy;
begin
  inherited;
end;

procedure TSenderStats.TransStateChange;
begin
  FTransState := TransState;
  case TransState of
    tsNego:
      begin
{$IFDEF CONSOLE}
        Writeln('Start Negotiations...');
{$ENDIF}
      end;
    tsTransing:
      begin
        FStartTime := GetTickCount;
        FPeriodStart := FStartTime;
{$IFDEF CONSOLE}
        Writeln('Start Trans..');
{$ENDIF}
      end;
    tsComplete:
      begin
        DoDisplay;
{$IFDEF CONSOLE}
        Writeln('Transfer Complete.');
{$ENDIF}
      end;
    tsExcept:
      begin
{$IFDEF CONSOLE}
        Writeln('Transfer Except!');
{$ENDIF}
      end;

    tsStop:
      begin
        PostMessage(frmCastFile.Handle, WM_AUTO_STOP, 0, 0);
{$IFDEF CONSOLE}
        Writeln('Stop.');
{$ENDIF}
      end;
  end;
end;

procedure TSenderStats.AddBytes(bytes: Integer);
begin
  Inc(FTotalBytes, bytes);
  DoDisplay;
end;

procedure TSenderStats.AddRetrans(nrRetrans: Integer);
begin
  Inc(FNrRetrans, nrRetrans);
  DoDisplay;
end;

procedure TSenderStats.DoDisplay();
var
  tickNow, tdiff    : DWORD;
  blocks            : dword;
  bw, percent       : double;
begin
  tickNow := GetTickCount;

  if FTransState = tsTransing then
  begin
    tdiff := DiffTickCount(FPeriodStart, tickNow);
    if (tdiff < FStatPeriod) then
      Exit;
    if tdiff = 0 then
      tdiff := 1;
    //����ͳ��
    bw := (FTotalBytes - FLastPosBytes) * 1000 / tdiff; // Byte/s
  end
  else
  begin
    tdiff := DiffTickCount(FStartTime, tickNow);
    if tdiff = 0 then
      tdiff := 1;
    //ƽ������ͳ��
    bw := FTotalBytes * 1000 / tdiff;   // Byte/s
  end;

  //�ش���ͳ��
  blocks := (FTotalBytes + FBlockSize - 1) div FBlockSize;
  if blocks = 0 then
    percent := 0
  else
    percent := FNrRetrans / blocks;
  //��ʾ״̬

  if g_FileSize > 0 then
    frmCastFile.pb1.Position := FTotalBytes * 100 div g_FileSize;
  frmCastFile.lblTransBytes.Caption := GetSizeKMG(FTotalBytes);
  frmCastFile.lblSpeed.Caption := GetSizeKMG(Trunc(bw)) + '/s';
  frmCastFile.lblRexmit.Caption := Format('%d(%.2f%%)', [FNrRetrans, percent]);

  FPeriodStart := GetTickCount;
  FLastPosBytes := FTotalBytes;
end;

{!--END--}

function TSenderStats.TransState: TTransState;
begin
  Result := FTransState;
end;

{ TPartsStats }

function TPartsStats.Add(index: Integer; addr: PSockAddrIn; sockBuf: Integer): Boolean;
var
  Item              : TListItem;
begin
  Result := True;
  Inc(FNrOnline);
  Item := frmCastFile.lvClient.Items.Add;
  Item.Caption := IntToStr(index);
  Item.SubItems.Add(inet_ntoa(addr^.sin_addr));
  Item.SubItems.Add(GetSizeKMG(sockBuf));

  PostMessage(frmCastFile.Handle, WM_UPDATE_ONLINE, 0, 0);
end;

function TPartsStats.Remove(index: Integer; addr: PSockAddrIn): Boolean;
var
  Item              : TListItem;
begin
  Result := True;
  Item := frmCastFile.lvClient.FindCaption(-1, IntToStr(index), False, False, False);
  if Assigned(Item) then
  begin
    Item.ImageIndex := 1;
    Dec(FNrOnline);
  end;

  PostMessage(frmCastFile.Handle, WM_UPDATE_ONLINE, 0, 0);
end;

function TPartsStats.GetNrOnline: Integer;
begin
  Result := FNrOnline;
end;

{!--END--}

{ TFileReader }

constructor TFileReader.Create(fileName: string; lpFifo: Pointer);
begin
  FFifo := lpFifo;
  FFile := TFileStream.Create(fileName, fmShareDenyNone or fmOpenRead);
  inherited Create(False);
end;

destructor TFileReader.Destroy;
begin
  if Assigned(FFile) then
    FFile.Free;
  inherited;
end;

procedure TFileReader.Execute;
var
  lpBuf             : PByte;
  dwBytes           : DWORD;
begin
  repeat
    dwBytes := 4096;
    lpBuf := DMCDataWriteWait(FFifo, dwBytes); //�ȴ����ݻ�������д
    if (dwBytes = 0) or Terminated then
      Break;

    dwBytes := FFile.Read(lpBuf^, dwBytes);
    DMCDataWrited(FFifo, dwBytes);

  until Terminated or (dwBytes = 0);
end;

procedure TFileReader.Terminate;
begin
  inherited Terminate;
  DMCDataWrited(FFifo, 0);
  WaitFor;
end;

procedure TfrmCastFile.btnStartClick(Sender: TObject);
var
  fileName          : string;
  config            : TSendConfig;
begin
  fileName := edtFile.Text;
  if FileExists(fileName) then
  begin
    pb1.Position := 0;
    pb1.Max := 100;
    lvClient.Clear;
    btnStart.Enabled := False;

    g_FileSize := GetFileSize(PAnsiChar(fileName));
    lblFileSize.Caption := GetSizeKMG(g_FileSize);
    pb1.Hint := '������ ' + lblFileSize.Caption;

    //Ĭ������
    DMCConfigFill(config);
    if chkStreamMode.Checked then
      config.dmcMode := dmcStreamMode;
    //config.net.mcastRdv:='239.0.0.1';

    config.retriesUntilDrop := seRetriesUntilDrop.Value;

    if chkAutoSliceSize.Checked then
      config.flags := config.flags + [dmcNotFullDuplex];

    config.default_slice_size := seSliceSize.Value;
    config.min_receivers := seWaitReceivers.Value;
    config.max_receivers_wait := seMaxWait.Value;

    //����
    FPartsStats := TPartsStats.Create;
    FSenderStats := TSenderStats.Create(config.blockSize, DEFLT_STAT_PERIOD);

    FNego := DMCNegoCreate(@config, FSenderStats, FPartsStats, FFifo);

    if Assigned(FFifo) then
      FFileReader := TFileReader.Create(fileName, FFifo);

    btnStop.Enabled := Assigned(FNego) and Assigned(FFifo);
    btnStart.Enabled := not btnStop.Enabled;
  end
  else
    MessageBox(Handle, '�ļ�������!', '��ʾ', MB_ICONWARNING);
end;

procedure TfrmCastFile.SpeedButton1Click(Sender: TObject);
begin
  if dlgOpen1.Execute then
    edtFile.Text := dlgOpen1.FileName;
end;

procedure TfrmCastFile.btnStopClick(Sender: TObject);
begin
  btnStop.Enabled := False;

  if FNego <> nil then
  begin
    // �ȴ�FIFO���߳̽���..
    FFileReader.Terminate;
    FFileReader.Free;

    DMCNegoDestroy(FNego);
    FNego := nil;
  end;

  btnStart.Enabled := FSenderStats.TransState = tsStop;
  btnTrans.Enabled := not btnStart.Enabled;

  //ѭ��ģʽ
  if btnStart.Enabled and chkLoopStart.Checked then
    btnStartClick(nil);
end;

procedure TfrmCastFile.btnTransClick(Sender: TObject);
begin
  if Assigned(FNego) then
    DMCDoTransfer(FNego)
  else
    btnStopClick(nil);
  btnTrans.Enabled := False;
end;

procedure TfrmCastFile.FormCreate(Sender: TObject);
begin
  pb1.DoubleBuffered := True;
end;

procedure TfrmCastFile.UpdateOnline;
begin
  btnTrans.Enabled := (FSenderStats.TransState = tsNego)
    and (FPartsStats.GetNrOnline > 0);
  stat1.Panels[0].Text := '�ͻ���: '
    + IntToStr(FPartsStats.GetNrOnline) + '/' + IntToStr(lvClient.Items.Count);
end;

procedure TfrmCastFile.OnAutoStop(var Msg: TMessage);
begin
  btnStopClick(nil);
end;

procedure TfrmCastFile.lbl8Click(Sender: TObject);
begin
  ShellExecute(Handle, 'open', 'http://www.yryz.net/?from=DMC',
    nil, nil, SW_SHOWNORMAL);
end;

end.

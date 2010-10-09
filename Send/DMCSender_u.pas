unit DMCSender_u;

interface
uses
  Windows, Messages, SysUtils, MyClasses,
  FuncLib, Config_u, Protoc_u, IStats_u,
  Negotiate_u, Fifo_u, SendData_u, HouLog_u;

type
  TSenderThread = class(TThread)
  private
    FStats: ISenderStats;
    FNego: TNegotiate;

    FDp: TDataPool;
    FRc: TRChannel;
    FSender: TSender;
  protected
    FIo: TFifo;
    procedure Execute; override;
    property Nego: TNegotiate read FNego;
  public
    constructor Create(config: PSendConfig; TransStats: ISenderStats;
      PartsStats: IPartsStats);
    destructor Destroy; override;
    procedure Terminate; overload;
  end;

  //API�ӿ�

  //���Ĭ������
procedure DMCConfigFill(var config: TSendConfig); stdcall;
//��ʼ�Ự  TransStats,PartsStats ����Ϊnil
function DMCNegoCreate(config: PSendConfig; TransStats: ISenderStats;
  PartsStats: IPartsStats; var lpFifo: Pointer): Pointer; stdcall;
//�ȴ���������д
function DMCDataWriteWait(lpFifo: Pointer; var dwBytes: DWORD): Pointer; stdcall;
//�����������
function DMCDataWrited(lpFifo: Pointer; dwBytes: DWORD): Boolean; stdcall;
//��ʼ����(�ź�)
function DMCDoTransfer(lpNego: Pointer): Boolean; stdcall;
//�����Ự(�ź�,�첽)
function DMCNegoDestroy(lpNego: Pointer): Boolean; stdcall;

implementation

procedure DMCConfigFill(var config: TSendConfig);
begin
  FillChar(config, SizeOf(config), 0);
  with config do
  begin
    with net do
    begin
      ifName := nil;                    //eth0 or 192.168.0.1 or 00-24-1D-99-64-D5 or nil(INADDR_ANY)
      localPort := 9080;                //9001
      remotePort := 8090;               //9000

      mcastRdv := nil;
      ttl := 1;

      sockRecvBufSize := 64 * 1024;
    end;

    flags := [];
    dmcMode := dmcFixedMode;
    blockSize := 1456;                  // ���ֵ��һЩ����£���������ߣ������ô��Ч�����Щ��10K

    min_slice_size := Protoc_u.MIN_SLICE_SIZE;
    max_slice_size := Protoc_u.MAX_SLICE_SIZE;

    rexmit_hello_interval := 1000;      //retransmit hello message
    retriesUntilDrop := 30;
    rehelloOffset := 50;
  end;
end;

function DMCNegoCreate(config: PSendConfig; TransStats: ISenderStats;
  PartsStats: IPartsStats; var lpFifo: Pointer): Pointer;
var
  Sender            : TSenderThread;
begin
  Sender := TSenderThread.Create(config, TransStats, PartsStats);
  lpFifo := Sender.FIo;
  Result := Sender;
  Sender.Resume;
end;

function DMCDataWriteWait(lpFifo: Pointer; var dwBytes: DWORD): Pointer;
var
  pos, bytes        : Integer;
begin
  pos := TFifo(lpFifo).FreeMemPC.GetConsumerPosition;
  bytes := TFifo(lpFifo).FreeMemPC.ConsumeContiguousMinAmount(dwBytes);
  if (bytes > (pos + bytes) mod DISK_BLOCK_SIZE) then
    Dec(bytes, (pos + bytes) mod DISK_BLOCK_SIZE);

  dwBytes := bytes;
  if bytes > 0 then
    Result := TFifo(lpFifo).GetDataBuffer(pos)
  else
    Result := nil;
end;

function DMCDataWrited(lpFifo: Pointer; dwBytes: DWORD): Boolean;
begin
  Result := True;
  try
    if (dwBytes > 0) then
    begin
      TFifo(lpFifo).FreeMemPC.Consumed(dwBytes);
      TFifo(lpFifo).DataPC.Produce(dwBytes);
    end
    else                                //no data
    begin
      TFifo(lpFifo).FreeMemPC.MarkEnd;
      TFifo(lpFifo).DataPC.MarkEnd;
    end;
  except on e: Exception do
    begin
      Result := False;
{$IFDEF EN_LOG}
      OutLog2(llError, e.Message);
{$ENDIF}
    end;
  end;
end;

function DMCDoTransfer(lpNego: Pointer): Boolean;
begin
  Result := True;
  try
    TSenderThread(lpNego).Nego.PostDoTransfer;
  except on e: Exception do
    begin
      Result := False;
{$IFDEF EN_LOG}
      OutLog2(llError, e.Message);
{$ENDIF}
    end;
  end;
end;

function DMCNegoDestroy(lpNego: Pointer): Boolean;
begin
  Result := True;
  try
    with TSenderThread(lpNego) do
    begin
      Terminate;
      Sleep(0);
      FreeOnTerminate := True;
      if Suspended then
        Resume;
    end;

  except on e: Exception do
    begin
      Result := False;
{$IFDEF EN_LOG}
      OutLog2(llError, e.Message);
{$ENDIF}
    end;
  end;
end;

{ TSenderThread }

constructor TSenderThread.Create(config: PSendConfig; TransStats: ISenderStats;
  PartsStats: IPartsStats);
begin
  FIo := TFifo.Create(config^.blockSize);
  FStats := TransStats;
  FNego := TNegotiate.Create(config, TransStats, PartsStats);
  inherited Create(True);
end;

destructor TSenderThread.Destroy;
begin
  Terminate;

  if Assigned(FIo) then
    FIo.Free;
  if Assigned(FNego) then
    FNego.Free;
  inherited;
end;

procedure TSenderThread.Execute;
begin
  try
    if FNego.StartNegotiate > 0 then
    begin                               //�������� >0
      FNego.BeginTrans();

      FDp := TDataPool.Create(FNego);
      FRc := TRChannel.Create(FNego, FDp);
      FSender := TSender.Create(FNego, FDp, FRc);
      FDp.InitSlice(FIo, FRc);

      FRc.Resume;                       //���ѷ�������
      FSender.Execute;                  //ִ�з���

      Self.Terminate;

      FreeAndNil(FSender);
      FreeAndNil(FRc);
      FreeAndNil(FDp);

      FNego.EndTrans();
    end;
  finally
    FNego.TransState := tsStop;
  end;

  //����(ȷ�������ܰ�ȫ�ͷ�)
  if not FreeOnTerminate then
    Suspend;
end;

procedure TSenderThread.Terminate;
begin
  inherited Terminate;

  try
    if Assigned(FSender) then
    begin
      FSender.Terminated := True;
      FDp.Close;
      FNego.USocket.Close;
      FRc.Terminate;
      FIo.Terminate;
    end
    else                                //�Ự��?
      FNego.StopNegotiate;
  except
  end;
end;

end.
 
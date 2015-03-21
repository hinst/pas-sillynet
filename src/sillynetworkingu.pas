unit SillyNetworkingU;

{$interfaces COM}

interface

uses
  types, Classes, windows, sysutils,
  blcksock, synsock;

type

  ISharedObject = interface
    function GetClassName: string;
  end;

  TSharedObject = class(TInterfacedObject, ISharedObject)
  public
    function GetClassName: string;
  end;

  ICriticalSection = interface(ISharedObject)
    function TryEnter: Boolean;
    procedure Enter;
    procedure Leave;
  end;

  TCriticalSection = class(TSharedObject, ICriticalSection)
  private
    InternalCriticalSection: TRTLCriticalSection;
  public
    constructor Create;
    function TryEnter: Boolean;
    procedure Enter;
    procedure Leave;
    destructor Destroy; override;
  end;

  TMemoryStreamDynArray = array of TMemoryStream;

  TMessageQueue = class
  private
    MessageArray: TMemoryStreamDynArray;
    Count: Integer;
    Locker: TRTLCriticalSection;
    procedure Shrink1;
  public
    constructor Create(aCountOfMessagesLimit: Integer);
    function Push(aMessage: TMemoryStream): Boolean;
    function Pop: TMemoryStream;
    destructor Destroy; override;
  end;

  TInt64MemoryBlock = array[0..7] of byte;

  TMessageReceiver = class
  strict private
    ExpectedSizeDataPosition: Byte;
    ExpectedSizeData: TInt64MemoryBlock;
    ExpectedSize: Int64;
    Memory: TMemoryStream;
    function Ready: Boolean;
  public
    constructor Create;
    procedure Write(aByte: byte);
    function Extract: TMemoryStream;
    destructor Destroy; override;
  end;

  TMethodThread = class;

  TMethodThreadMethod = procedure(aThread: TMethodThread) of object;

  TMethodThread = class(TThread)
  private
    Method: TMethodThreadMethod;
  protected
    procedure Execute; override;
    procedure WriteLog(s: string);
  public
    property Terminated;
    constructor Create(aMethod: TMethodThreadMethod);
  end;

  TClient = class
  private
    MessageReceiver: TMessageReceiver;
    Incoming: TMessageQueue;
    Outgoing: TMessageQueue;
    Socket: TTCPBlockSocket;
    ReaderThread: TMethodThread;
    WriterThread: TMethodThread;
    ConnectionActiveF: Boolean;
    KeepAliveInterval: Cardinal;
    procedure ReaderRoutine(aThread: TMethodThread);
    procedure WriterRoutine(aThread: TMethodThread);
    function CheckConnectionActive: Boolean;
    procedure WriteLog(aMessage: string);
  public
    TargetAddress: string;
    TargetPort: Word;
    ThreadIdleInterval: Integer;
    property ConnectionActive: Boolean read ConnectionActiveF;
    constructor Create;
    procedure Start;
    procedure Stop;
    procedure Push(aMessage: TMemoryStream);
    function Pop: TMemoryStream;
    destructor Destroy; override;
  end;

  // For testing purposes.
  TEchoClient = class
  private
    Client: TClient;
    EchoThread: TMethodThread;
    procedure SetTargetAddress(a: string);
    procedure SetTargetPort(a: Word);
    procedure EchoThreadRoutine(a: TMethodThread);
  public
    property TargetAddress: string write SetTargetAddress;
    property TargetPort: Word write SetTargetPort;
    constructor Create;
    procedure Start;
    procedure Stop;
    destructor Destroy; override;
  end;

const
  DefaultMessageBufferLimit = 10 * 1000;
  DefaultThreadIdleInterval = 100;
  DefaultKeepAliveInterval = 3000;
  DefaultDateTimeFormat = 'yyyy-mm-dd_hh-nn-ss';

var
  LogFileLocation: string;
  LogFileHandle: THandle;

procedure Initialize;
procedure Finalize;

implementation

{$REGION EXCEPTION}
function ExceptionCallStackToStrings: TStringDynArray;
var
  i: Integer;
  frames: PPointer;
begin
  SetLength(result, 1 + ExceptFrameCount);
  frames := ExceptFrames;
  result[0] := BackTraceStrFunc(ExceptAddr);
  for i := 0 to ExceptFrameCount - 1 do
    result[i + 1] := BackTraceStrFunc(frames[i]);
end;

function JoinStringArray(aStringArray: TStringDynArray; aSeparator: string): string;
var
  i: Integer;
begin
  result := '';
  for i := 0 to Length(aStringArray) - 1 do
  begin
    result := result + aStringArray[i];
    if i < Length(aStringArray) - 1 then
      result := result + aSeparator;
  end;
end;

function ExceptionCallStackToText: string;
begin
  result := JoinStringArray(ExceptionCallStackToStrings, LineEnding);
end;

function ExceptionToText(e: Exception): string;
begin
  result := e.ClassName + ': "' + e.Message + '"' + LineEnding + ExceptionCallStackToText;
end;

{$ENDREGION}

{$REGION INT_64_MEMBLOCK}

function Int64ToMemoryBlock(aX: Int64): TInt64MemoryBlock;
var
  i: Byte;
begin
  for i := 0 to SizeOf(aX) - 1 do
  begin
    result[i] := (aX shr (i * 8)) and $FF;
  end;
end;

function MemoryBlockToInt64(aBlock: TInt64MemoryBlock): Int64;
var
  i: Byte;
begin
  result := 0;
  for i := 0 to SizeOf(result) - 1 do
    result := result + (aBlock[i] shl (i * 8));
end;

{$ENDREGION}

{$REGION LOG}

function GetDefaultLogFileLocation: string;
var
  currentMoment: TDateTime;
begin
  currentMoment := Now;
  result := 'silly_networking_log_'
    + FormatDateTime('yyyy-mm-dd_hh-nn-ss', currentMoment) + '.txt';
end;

procedure CreateLogFile;
begin
  LogFileHandle := CreateFile(PChar(GetDefaultLogFileLocation),
    GENERIC_WRITE, FILE_SHARE_READ, nil, CREATE_ALWAYS,FILE_ATTRIBUTE_NORMAL,0);
end;

procedure WriteLog(text: string);
var
  writeResult: DWORD;
begin
  text := FormatDateTime(DefaultDateTimeFormat, Now) + ' ' + IntToHex(GetCurrentThreadId, 8) + ': '
    + text + LineEnding;
  writeResult := 0;
  WriteFile(LogFileHandle, text[1], Length(text), writeResult, nil);
end;

procedure CloseLogFile;
begin
  CloseHandle(LogFileHandle);
  LogFileHandle := 0;
end;

{$ENDREGION}

procedure Initialize;
begin
  CreateLogFile;
  WriteLog('Log file created');
end;

procedure Finalize;
begin
  WriteLog('Closing log file');
  CloseLogFile;
end;

{ TEchoClient }

procedure TEchoClient.SetTargetAddress(a: string);
begin
  Client.TargetAddress := a;
end;

procedure TEchoClient.SetTargetPort(a: Word);
begin
  Client.TargetPort := a;
end;

procedure TEchoClient.EchoThreadRoutine(a: TMethodThread);
  procedure Tick;
  var
    m: TMemoryStream;
  begin
    m := Client.Incoming.Pop;
    if m <> nil then
      Client.Outgoing.Push(m);
  end;

begin
  while not a.Terminated do
  begin
    Tick;
  end;
  Tick;
end;

constructor TEchoClient.Create;
begin
  inherited Create;
  Client := TClient.Create;
end;

procedure TEchoClient.Start;
begin
  Client.Start;
  EchoThread := TMethodThread.Create(@EchoThreadRoutine);
end;

procedure TEchoClient.Stop;
begin
  if EchoThread <> nil then
  begin
    EchoThread.Terminate;
    EchoThread.WaitFor;
    EchoThread.Free;
    EchoThread := nil;
  end;
  Client.Stop;
end;

destructor TEchoClient.Destroy;
begin
  inherited Destroy;
end;

procedure TClient.ReaderRoutine(aThread: TMethodThread);

  procedure ConnectForward;
  begin
    if (TargetAddress <> '') and (TargetPort <> 0) then
    begin
      Socket.Connect(TargetAddress, IntToStr(TargetPort));
      if Socket.LastError = 0 then
      begin
        ConnectionActiveF := True;
        WriteLog('Connected');
      end
      else
      begin
        Socket.CloseSocket;
        ConnectionActiveF := False;
        WriteLog('Tried to connect; failed; Socket.LastError = ' + IntToStr(Socket.LastError)
          +', Socket.LastErrorDesc = "' + Socket.LastErrorDesc + '"');
      end;
    end;
  end;

  procedure ReadForward;

    function Read(out aByte: Byte): Boolean;
    begin
      aByte := self.Socket.RecvByte(1);
      result := self.Socket.LastError = 0;
    end;

    // MessageReceiver.Ready must be = True.
    procedure TryExtractMessage;
    var
      pushResult: Boolean;
      incomingMessage: TMemoryStream;
    begin
      incomingMessage := MessageReceiver.Extract;
      if incomingMessage <> nil then
      begin
        pushResult := Incoming.Push(incomingMessage);
        if not pushResult then
          incomingMessage.Free;
      end;
    end;

  var
    byteL: Byte;
  begin
    while ConnectionActive and Read(byteL) do
    begin
      MessageReceiver.Write(byteL);
      TryExtractMessage;
      ConnectionActiveF := CheckConnectionActive;
      if not ConnectionActiveF then
      begin
        Socket.CloseSocket;
      end;
    end;
  end;

begin
  WriteLog('Reader routine started');
  while not aThread.Terminated do
  begin
    if not ConnectionActive then
      ConnectForward;
    if ConnectionActive then
      ReadForward;
    SysUtils.Sleep(ThreadIdleInterval);
  end;
  ReadForward;
end;

procedure TClient.WriterRoutine(aThread: TMethodThread);

var
  lastKeepAliveMoment: QWord;

  procedure WriteMessage(aMessage: TMemoryStream);
  var
    sizeData: TInt64MemoryBlock;
  begin
    sizeData := Int64ToMemoryBlock(aMessage.Size);
    Socket.SendBuffer(@sizeData[0], SizeOf(Int64));
    Socket.SendBuffer(aMessage.Memory, Integer(aMessage.Size));
  end;

  procedure SendKeepAliive;
  var
    emptyMessage: TMemoryStream;
  begin
    emptyMessage := TMemoryStream.Create;
    WriteMessage(emptyMessage);
    emptyMessage.Free;
  end;

  procedure SendKeepAliveIfRequired;
  begin
    if KeepAliveInterval < GetTickCount64 - lastKeepAliveMoment then
    begin
      SendKeepAliive;
      lastKeepAliveMoment := GetTickCount64;
    end;
  end;

  procedure WriteForward;
  var
    outgoingMessage: TMemoryStream;
  begin
    while self.ConnectionActive do
    begin
      outgoingMessage := Outgoing.Pop;
      if outgoingMessage <> nil then
      begin
        WriteMessage(outgoingMessage);
        outgoingMessage.Free;
        ConnectionActiveF := CheckConnectionActive;
        if not ConnectionActiveF then
          Socket.CloseSocket;
      end
      else
        break;
    end;
  end;

begin
  while not aThread.Terminated do
  begin
    WriteForward;
    SysUtils.Sleep(ThreadIdleInterval);
  end;
  WriteForward;
end;

function TClient.CheckConnectionActive: Boolean;
begin
  result := (Socket.LastError = 0) or (Socket.LastError = WSAETIMEDOUT);
end;

procedure TClient.WriteLog(aMessage: string);
begin
  SillyNetworkingU.WriteLog('TClient: ' + aMessage);
end;

constructor TClient.Create;
begin
  inherited Create;
  KeepAliveInterval := DefaultKeepAliveInterval;
  ThreadIdleInterval := DefaultThreadIdleInterval;
  MessageReceiver := TMessageReceiver.Create;
  Incoming := TMessageQueue.Create(DefaultMessageBufferLimit);
  Outgoing := TMessageQueue.Create(DefaultMessageBufferLimit);
  Socket := TTCPBlockSocket.Create;
end;

procedure TClient.Start;
begin
  if nil = ReaderThread then
    ReaderThread := TMethodThread.Create(@ReaderRoutine);
  if nil = WriterThread then
    WriterThread := TMethodThread.Create(@WriterRoutine);
end;

procedure TClient.Stop;
begin
  if WriterThread <> nil then
  begin
    WriterThread.Terminate;
    WriterThread.WaitFor;
    WriterThread.Free;
    WriterThread := nil;
  end;
  if ReaderThread <> nil then
  begin
    ReaderThread.Terminate;
    ReaderThread.WaitFor;
    ReaderThread.Free;
    ReaderThread := nil;
  end;
  Socket.CloseSocket;
end;

procedure TClient.Push(aMessage: TMemoryStream);
begin
  Outgoing.Push(aMessage);
end;

function TClient.Pop: TMemoryStream;
begin
  result := Incoming.Pop;
end;

destructor TClient.Destroy;
begin
  Stop;
  Outgoing.Free;
  Incoming.Free;
  MessageReceiver.Free;
  Socket.Free;
  inherited Destroy;
end;

constructor TMethodThread.Create(aMethod: TMethodThreadMethod);
begin
  inherited Create(True);
  self.Method := aMethod;
  Start;
end;

procedure TMethodThread.Execute;
begin
  try
    Method(self);
  except
    on e: Exception do
      WriteLog('Exception in thread ' + ExceptionToText(e));
  end;
end;

procedure TMethodThread.WriteLog(s: string);
begin
  SillyNetworkingU.WriteLog(self.ClassName + ': ' + s)
end;

procedure TMessageQueue.Shrink1;
var
  i: Integer;
begin
  for i := 0 to Count - 2 do
    self.MessageArray[i] := self.MessageArray[i + 1];
  Dec(Count);
end;

constructor TMessageQueue.Create(aCountOfMessagesLimit: Integer);
begin
  inherited Create;
  InitCriticalSection(Locker);
  SetLength(MessageArray, aCountOfMessagesLimit);
end;

function TMessageQueue.Push(aMessage: TMemoryStream): Boolean;
begin
  EnterCriticalsection(Locker);
  result := self.Count < Length(self.MessageArray);
  if result then
  begin
    self.MessageArray[self.Count] := aMessage;
    Inc(self.Count);
  end;
  LeaveCriticalsection(Locker);
end;

function TMessageQueue.Pop: TMemoryStream;
begin
  result := nil;
  EnterCriticalsection(Locker);
  if self.Count > 0 then
  begin
    result := self.MessageArray[0];
    Shrink1;
  end;
  LeaveCriticalsection(Locker);
end;

destructor TMessageQueue.Destroy;
begin
  DoneCriticalsection(Locker);
  inherited Destroy;
end;

constructor TMessageReceiver.Create;
begin
  inherited Create;
  Memory := TMemoryStream.Create;
  Memory.Size := DefaultMessageBufferLimit;
end;

procedure TMessageReceiver.Write(aByte: byte);
begin
  if ExpectedSizeDataPosition < SizeOf(ExpectedSize) then
  begin
    ExpectedSizeData[ExpectedSizeDataPosition] := aByte;
    Inc(ExpectedSizeDataPosition);
    if ExpectedSizeDataPosition = SizeOf(ExpectedSize) then
      ExpectedSize := MemoryBlockToInt64(ExpectedSizeData);
  end
  else
    Memory.WriteByte(aByte);
end;

function TMessageReceiver.Ready: Boolean;
begin
  result := (ExpectedSizeDataPosition = SizeOf(ExpectedSize)) and (ExpectedSize = Memory.Size);
end;

function TMessageReceiver.Extract: TMemoryStream;
begin
  if Ready then
  begin
    result := TMemoryStream.Create;
    result.Size := Memory.Position;
    Memory.Position := 0;
    result.CopyFrom(Memory, result.Size);
    Memory.Position := 0;
  end
  else
    result := nil;
end;

destructor TMessageReceiver.Destroy;
begin
  Memory.Free;
  inherited Destroy;
end;

function TSharedObject.GetClassName: string;
begin
  result := self.ClassName;
end;

constructor TCriticalSection.Create;
begin
  System.InitCriticalSection(InternalCriticalSection);
end;

function TCriticalSection.TryEnter: Boolean;
begin
  result := System.TryEnterCriticalsection(InternalCriticalSection) <> 0;
end;

procedure TCriticalSection.Enter;
begin
  System.EnterCriticalsection(InternalCriticalSection);
end;

procedure TCriticalSection.Leave;
begin
  System.LeaveCriticalsection(InternalCriticalSection);
end;

destructor TCriticalSection.Destroy;
begin
  inherited Destroy;
end;

end.


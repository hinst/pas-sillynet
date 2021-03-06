unit SillyNetworkingU;

{$interfaces COM}

interface

uses
  types, Classes, windows, sysutils, syncobjs,
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
    TempMemory: TMemoryStream;
    function Ready: Boolean;
    procedure ShiftLeft(aRightPosition: Int64);
  public
    constructor Create;
    procedure Write(const aBuffer: PByte; const aLength: Integer);
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
    PushEvent: TEvent;
    procedure ReaderRoutine(aThread: TMethodThread);
    procedure WriterRoutine(aThread: TMethodThread);
    function CheckConnectionActive: Boolean;
    procedure WriteLog(aMessage: string);
  public
    // Pluggable.
    IncomingMessageEvent: TEvent;
    TargetAddress: string;
    TargetPort: Word;
    ThreadIdleInterval: DWord;
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
    EchoThreadEvent: TEvent;
    procedure SetTargetAddress(a: string);
    procedure SetTargetPort(a: Word);
    procedure SetThreadIdleInterval(a: DWord);
    procedure EchoThreadRoutine(a: TMethodThread);
  public
    property TargetAddress: string write SetTargetAddress;
    property TargetPort: Word write SetTargetPort;
    property ThreadIdleInterval: DWORD write SetThreadIdleInterval;
    constructor Create;
    procedure Start;
    procedure Stop;
    destructor Destroy; override;
  end;

const
  DefaultMessageBufferLimit = 10 * 1000;
  DefaultThreadIdleInterval = 10;
  DefaultKeepAliveInterval = 3000;
  DefaultDateTimeFormat = 'yyyy-mm-dd_hh-nn-ss';
  DefaultRecvBufferLength = 1;

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
  currentValue: Int64;
begin
  result := 0;
  for i := 0 to SizeOf(result) - 1 do
  begin
    currentValue := aBlock[i];
    result := result or (currentValue shl (i * 8));
  end;
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

procedure TEchoClient.SetThreadIdleInterval(a: DWord);
begin
  Client.ThreadIdleInterval := a;
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
    EchoThreadEvent.WaitFor(5);
  end;
  Tick;
end;

constructor TEchoClient.Create;
begin
  inherited Create;
  Client := TClient.Create;
  EchoThreadEvent := TEvent.Create(nil, false, false, '');
  Client.IncomingMessageEvent := EchoThreadEvent;
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
    EchoThreadEvent.SetEvent;
    EchoThread.WaitFor;
    EchoThread.Free;
    EchoThread := nil;
  end;
  Client.Stop;
end;

destructor TEchoClient.Destroy;
begin
  Stop;
  inherited Destroy;
end;

procedure TClient.ReaderRoutine(aThread: TMethodThread);
var
  buffer: TByteDynArray;

  procedure ConnectForward;
  begin
    if (TargetAddress <> '') and (TargetPort <> 0) then
    begin
      Socket.Connect(TargetAddress, IntToStr(TargetPort));
      if Socket.LastError = 0 then
      begin
        ConnectionActiveF := True;
        WriteLog('Successfully connected to address "' + TargetAddress + '" '
          + 'port ' + IntToStr(TargetPort));
      end
      else
      begin
        Socket.CloseSocket;
        ConnectionActiveF := False;
        WriteLog('Tried to connect; failed; Socket.LastError = ' + IntToStr(Socket.LastError) + ', '
          + 'Socket.LastErrorDesc = "' + Socket.LastErrorDesc + '"; '
          + 'target address is "' + TargetAddress + '", port ' + IntToStr(TargetPort));
      end;
    end;
  end;

  procedure ReadForward;

    function ReadBuffer: Integer;
    begin
      result := self.Socket.RecvBufferEx(@buffer[0], Length(buffer), 1);
    end;

    procedure TryExtractMessages;
    var
      pushResult: Boolean;
      incomingMessage: TMemoryStream;
    begin
      incomingMessage := MessageReceiver.Extract;
      while incomingMessage <> nil do
      begin
        pushResult := Incoming.Push(incomingMessage);
        if IncomingMessageEvent <> nil then
          IncomingMessageEvent.SetEvent;
        if not pushResult then
          incomingMessage.Free;
        incomingMessage := MessageReceiver.Extract;
      end;
    end;

  var
    incomingDataLength: Integer;
  begin
    while ConnectionActive do
    begin
      while True do
      begin
        incomingDataLength := ReadBuffer;
        if incomingDataLength > 0 then
        begin
          MessageReceiver.Write(@buffer[0], incomingDataLength);
          TryExtractMessages;
        end
        else
          break;
      end;
      ConnectionActiveF := CheckConnectionActive;
      if not ConnectionActiveF then
        Socket.CloseSocket;
    end;
  end;

begin
  SetLength(buffer, DefaultRecvBufferLength);
  while not aThread.Terminated do
  begin
    if not ConnectionActive then
      ConnectForward;
    if ConnectionActive then
      ReadForward
    else
      SysUtils.Sleep(1000); // failed to connect; do not attempt to connect again right away.
    //SysUtils.Sleep(ThreadIdleInterval);
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
    WriteLog('WriteMessage: ' + IntToStr(aMessage.Size));
    Socket.SendBuffer(@sizeData[0], SizeOf(Int64));
    if aMessage.Size > 0 then
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
    PushEvent.WaitFor(ThreadIdleInterval);
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
  PushEvent := TEvent.Create(nil, false, false, '');
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
  ConnectionActiveF := False;
end;

procedure TClient.Push(aMessage: TMemoryStream);
begin
  Outgoing.Push(aMessage);
  PushEvent.SetEvent;
end;

function TClient.Pop: TMemoryStream;
begin
  result := Incoming.Pop;
end;

destructor TClient.Destroy;
begin
  Stop;
  Outgoing.Free;
  PushEvent.Free;;
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
  Memory.Position := 0;
  TempMemory := TMemoryStream.Create;
  TempMemory.Size := DefaultMessageBufferLimit;
  TempMemory.Position := 0;
end;

procedure TMessageReceiver.Write(const aBuffer: PByte; const aLength: Integer);
var
  offset: Integer;
begin
  offset := 0;
  while (ExpectedSizeDataPosition < SizeOf(ExpectedSize)) and (offset < aLength) do
  begin
    ExpectedSizeData[ExpectedSizeDataPosition] := aBuffer[offset];
    Inc(ExpectedSizeDataPosition);
    Inc(offset);
    if ExpectedSizeDataPosition = SizeOf(ExpectedSize) then
      ExpectedSize := MemoryBlockToInt64(ExpectedSizeData);
  end;
  if offset < aLength then
    Memory.Write(aBuffer[offset], aLength - offset);
end;

function TMessageReceiver.Ready: Boolean;
begin
  result := (ExpectedSizeDataPosition = SizeOf(ExpectedSize)) and (ExpectedSize <= Memory.Position);
end;

procedure TMessageReceiver.ShiftLeft(aRightPosition: Int64);
var
  leftOverLength: Int64;
begin
  leftOverLength := aRightPosition - ExpectedSize;
  ExpectedSizeDataPosition := 0;
  Memory.Position := 0;
  if leftOverLength > 0 then
  begin
    Memory.Position := ExpectedSize;
    TempMemory.Position := 0;
    TempMemory.CopyFrom(Memory, leftOverLength);
    Memory.Position := 0;
    Write(PByte(TempMemory.Memory), leftOverLength);
  end;
end;

// Beware: TStream.CopyFrom copies everything when specifying length = 0.
function TMessageReceiver.Extract: TMemoryStream;
var
  rightPosition: Int64;
begin
  if Ready then
  begin
    rightPosition := Memory.Position;
    result := TMemoryStream.Create;
    WriteLog(IntToStr(ExpectedSize));
    if ExpectedSize > 0 then
    begin
      result.Size := ExpectedSize;
      result.Position := 0;
      Memory.Position := 0;
      result.CopyFrom(Memory, result.Size);
    end;
    ShiftLeft(rightPosition);
  end
  else
    result := nil;
end;

destructor TMessageReceiver.Destroy;
begin
  Memory.Free;
  TempMemory.Free;
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


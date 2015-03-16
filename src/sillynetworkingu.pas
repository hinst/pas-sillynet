unit SillyNetworkingU;

{$interfaces COM}

interface

uses
  Classes, windows, SysUtils, blcksock, synsock;

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
  private
    ExpectedSizeDataPosition: Byte;
    ExpectedSizeData: TInt64MemoryBlock;
    ExpectedSize: Int64;
  public
    Memory: TMemoryStream;
    constructor Create;
    procedure Write(aByte: byte);
    function Ready: Boolean;
    destructor Destroy; override;
  end;

  TMethodThread = class;

  TMethodThreadMethod = procedure(aThread: TMethodThread) of object;

  TMethodThread = class(TThread)
  private
    Method: TMethodThreadMethod;
  public
    property Terminated;
    constructor Create(aMethod: TMethodThreadMethod);
    procedure Execute; override;
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

implementation

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
        ConnectionActiveF := True
      else
      begin
        Socket.CloseSocket;
        ConnectionActiveF := False;
      end;
    end;
  end;

  function Read(out aByte: Byte): Boolean;
  begin
    aByte := self.Socket.RecvByte(1);
    result := self.Socket.LastError = 0;
  end;

  procedure ReadForward;

    // MessageReceiver.Ready must be = True.
    procedure ExtractMessage;
    var
      pushResult: Boolean;
      incomingMessage: TMemoryStream;
    begin
      incomingMessage := MessageReceiver.Memory;
      MessageReceiver.Memory := nil;
      MessageReceiver.Free;
      MessageReceiver := TMessageReceiver.Create;
      pushResult := Incoming.Push(incomingMessage);
      if not pushResult then
        incomingMessage.Free;
    end;

  var
    byteL: Byte;
  begin
    while ConnectionActive and Read(byteL) do
    begin
      MessageReceiver.Write(byteL);
      if MessageReceiver.Ready then
        ExtractMessage;
      ConnectionActiveF := CheckConnectionActive;
      if not ConnectionActiveF then
        Socket.CloseSocket;
    end;
  end;

begin
  while not aThread.Terminated do
  begin
    if not ConnectionActive then
      ConnectForward;
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

constructor TClient.Create;
begin
  inherited Create;
  KeepAliveInterval := DefaultKeepAliveInterval;
  ThreadIdleInterval := DefaultThreadIdleInterval;
  MessageReceiver := TMessageReceiver.Create;
  Incoming := TMessageQueue.Create(DefaultMessageBufferLimit);
  Outgoing := TMessageQueue.Create(DefaultMessageBufferLimit);
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
  Method(self);
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


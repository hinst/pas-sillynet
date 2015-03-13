unit SillyNetworkingU;

{$interfaces COM}

interface

uses
  Classes, SysUtils, blcksock;

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

  TMessageReceiver = class
  private
    SizePos: Byte;
    ExpectedSize: Int64;
    MemoryF: TMemoryStream;
  public
    constructor Create;
    procedure Write(aByte: byte);
    function Ready: Boolean;
    procedure Reset;
    property Memory: TMemoryStream read MemoryF;
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
    procedure ReaderRoutine(aThread: TMethodThread);
    procedure WriterRoutine(aThread: TMethodThread);
  public
    TargetAddress: string;
    TargetPort: Word;
    ThreadIdleInterval: Integer;
    property ConnectionActive: Boolean read ConnectionActiveF;
    constructor Create;
    procedure Start;
    procedure Push(aMessage: TMemoryStream);
    function Pop: TMemoryStream;
    destructor Destroy; override;
  end;

const
  DefaultMessageBufferLimit = 10 * 1000;
  DefaultThreadIdleInterval = 100;

implementation

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
      MessageReceiver.Reset;
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
begin
  while not aThread.Terminated do
  begin

  end;
end;

constructor TClient.Create;
begin
  inherited Create;
  MessageReceiver := TMessageReceiver.Create;
  Incoming := TMessageQueue.Create(DefaultMessageBufferLimit);
  Outgoing := TMessageQueue.Create(DefaultMessageBufferLimit);
end;

procedure TClient.Start;
begin
  ReaderThread := TMethodThread.Create(@ReaderRoutine);
  WriterThread := TMethodThread.Create(@WriterRoutine);
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
  MemoryF := TMemoryStream.Create;
end;

procedure TMessageReceiver.Write(aByte: byte);
begin
  if SizePos < SizeOf(ExpectedSize) then
  begin
    ExpectedSize := ExpectedSize + aByte shl (SizePos * 8);
    Inc(SizePos);
  end
  else
  begin
    MemoryF.WriteByte(aByte);
  end;
end;

function TMessageReceiver.Ready: Boolean;
begin
  result := (SizePos = SizeOf(ExpectedSize)) and (MemoryF.Size <= ExpectedSize);
end;

procedure TMessageReceiver.Reset;
begin
  SizePos := 0;
  MemoryF := TMemoryStream.Create;
end;

destructor TMessageReceiver.Destroy;
begin
  MemoryF.Free;
  inherited Destroy;
end;

function TSharedObject.GetClassName: string;
begin
  result := self.ClassName;
end;

constructor TCriticalSection.Create;
begin
  InitCriticalSection(InternalCriticalSection);
end;

function TCriticalSection.TryEnter: Boolean;
begin
  result := TryEnterCriticalsection(InternalCriticalSection) <> 0;
end;

procedure TCriticalSection.Enter;
begin
  EnterCriticalsection(InternalCriticalSection);
end;

procedure TCriticalSection.Leave;
begin
  LeaveCriticalsection(InternalCriticalSection);
end;

destructor TCriticalSection.Destroy;
begin
  inherited Destroy;
end;

end.


unit SillyNetworkingU;

{$interfaces COM}

interface

uses
  Classes, SysUtils;

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
  end;

implementation

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

end.


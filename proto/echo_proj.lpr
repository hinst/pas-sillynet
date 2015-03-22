program echo_proj;

uses SillyNetworkingU;

var
  commandString: string;
  client: TEchoClient;

begin
  SillyNetworkingU.Initialize;
  commandString := '';
  client := TEchoClient.Create;
  client.TargetAddress := 'localhost';
  client.TargetPort := 9077;
  client.ThreadIdleInterval := 5;
  client.Start;
  while commandString <> 'exit' do
  begin
    Write('>');
    ReadLN(commandString);
    if commandString = 'start' then
    begin
      WriteLN('Now starting client...');
      client.Start;
    end
    else if commandString = 'stop' then
    begin
      WriteLN('Now stopping client...');
      client.Stop;
    end
  end;
  client.Free;
  SillyNetworkingU.Finalize;
end.


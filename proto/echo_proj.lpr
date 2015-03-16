program echo_proj;

uses SillyNetworkingU;

var
  commandString: string;
  client: TClient;

begin
  commandString := '';
  client := TClient.Create;
  client.TargetAddress := 'localport';
  client.TargetPort := 9077;
  while commandString <> 'exit' do
  begin
    ReadLN(commandString);
    if commandString = 'start' then
      client.Start
    else if commandString = 'stop' then
      client.Stop;
  end;
  client.Free;
end.


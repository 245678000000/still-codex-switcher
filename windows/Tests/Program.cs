if (args.Contains("app-server")) return await Still.Tests.FakeServer.Run();
var core = await Still.Tests.TestSuite.Run(Console.WriteLine);
var pipes = await Still.Tests.ProcessTests.Run(Console.WriteLine);
return core && pipes ? 0 : 1;

Code.require_file("../fixtures/fixture.exs", __DIR__)

Faction.Fixture.compile!()
ExUnit.start()

using Test, TestPackage2


@static if Sys.iswindows()
  @test hello2("Julia") == "Hello, Julia"

elseif Sys.islinux() || Sys.isapple()
  @test domath2(2.0) ≈ 7.0

end

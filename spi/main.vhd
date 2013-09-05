library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity main is
	port(
		-- 12 MHz clock input
		clock12mhz: in std_logic;
			
		-- microcontroller SPI interface
		spiMosi: in std_logic;
		spiMiso: out std_logic;
		spiCS: in std_logic;
		spiClock: in std_logic
	);
end main;

architecture rtl of main is
	-- PLL generated 96 MHz clock
	signal clock96mhz: std_logic;

	-- host communication interface
	signal commChanAddr: std_logic_vector(6 downto 0);
	signal commChanWrite: std_logic;
	signal commStart: std_logic;
	signal commH2fData: std_logic_vector(7 downto 0);
	signal commH2fValid: std_logic;
	signal commF2hData: std_logic_vector(7 downto 0);
	signal commF2hReady: std_logic;
	signal shiftRegister: std_logic_vector(31 downto 0);
	type CommStateType is (
		idle,
		writeRAM,
		readRAM,
		writeRegister,
		readRegister
	);
	signal commState: CommStateType := idle;
	signal byteCount: natural range 0 to 4;

	-- some registers for testing
	type RegistersType is array (0 to 5) of unsigned(31 downto 0);
	signal registers: RegistersType := (others => x"00000000");
	
begin

	clock_inst: entity clock
	port map(
        CLKI => clock12mhz,
		CLKOP => clock96mhz
	);

	comm_fpga_spi_inst: entity comm_fpga_spi
	port map(
		clock => clock96mhz,
		mosi => spiMosi,
		miso => spiMiso,
		cs => spiCS,
		sck => spiClock,
		chanAddr_out => commChanAddr,
		chanWrite_out => commChanWrite,
		start => commStart,
		h2fData_out => commH2fData,
		h2fValid_out => commH2fValid,
		f2hData_in => commF2hData,
		f2hReady_out => commF2hReady
	);
		
	control: process(clock96mhz)
	begin
		if rising_edge(clock96mhz) then
			if commStart = '1' then
				byteCount <= 0;
				if commChanWrite = '1' then
					commState <= writeRegister;
				else
					shiftRegister <= registers(to_integer(unsigned(commChanAddr)));
					commState <= readRegister;
				end if;
			end if;

			case commState is
				when idle => null;

				when writeRegister =>
					-- update register when 4 bytes were received, then back to idle
					if byteCount = 4 then
						registers(to_integer(unsigned(commChanAddr))) <= shiftRegister;
						commState <= idle;
					end if;

					-- host writes data to a register
					if commH2fValid = '1' then
						shiftRegister <= shiftRegister(23 downto 0) & commH2fData;
						byteCount <= byteCount + 1;
					end if;

				when readRegister =>
					-- back to idle, when 4 bytes were received
					if byteCount = 4 then
						commState <= idle;
					end if;

					-- host reads data from a register
					if commF2hReady = '1' then
						commF2hData <= shiftRegister(31 downto 24);
						shiftRegister <= shiftRegister(23 downto 0) & x"00";
						byteCount <= byteCount + 1;
					end if;
			end case;
		end if;
	end process;

end architecture rtl;

//! Bluetooth SIG assigned numbers: GAP Appearance values.
//! GENERATED from the official SIG YAML (see tools/gen_db.py).
//! appearance = category << 6 | subcategory.

const std = @import("std");

pub const Sub = struct { v: u8, name: []const u8 };
pub const Category = struct {
    id: u8,
    name: []const u8,
    subs: []const Sub = &.{},
};

pub const categories = [_]Category{
    .{ .id = 0x00, .name = "Unknown" },
    .{ .id = 0x01, .name = "Phone" },
    .{ .id = 0x02, .name = "Computer", .subs = &subs_02 },
    .{ .id = 0x03, .name = "Watch", .subs = &subs_03 },
    .{ .id = 0x04, .name = "Clock" },
    .{ .id = 0x05, .name = "Display" },
    .{ .id = 0x06, .name = "Remote Control" },
    .{ .id = 0x07, .name = "Eye-glasses" },
    .{ .id = 0x08, .name = "Tag" },
    .{ .id = 0x09, .name = "Keyring" },
    .{ .id = 0x0A, .name = "Media Player" },
    .{ .id = 0x0B, .name = "Barcode Scanner" },
    .{ .id = 0x0C, .name = "Thermometer", .subs = &subs_0C },
    .{ .id = 0x0D, .name = "Heart Rate Sensor", .subs = &subs_0D },
    .{ .id = 0x0E, .name = "Blood Pressure", .subs = &subs_0E },
    .{ .id = 0x0F, .name = "Human Interface Device", .subs = &subs_0F },
    .{ .id = 0x10, .name = "Glucose Meter" },
    .{ .id = 0x11, .name = "Running Walking Sensor", .subs = &subs_11 },
    .{ .id = 0x12, .name = "Cycling", .subs = &subs_12 },
    .{ .id = 0x13, .name = "Control Device", .subs = &subs_13 },
    .{ .id = 0x14, .name = "Network Device", .subs = &subs_14 },
    .{ .id = 0x15, .name = "Sensor", .subs = &subs_15 },
    .{ .id = 0x16, .name = "Light Fixtures", .subs = &subs_16 },
    .{ .id = 0x17, .name = "Fan", .subs = &subs_17 },
    .{ .id = 0x18, .name = "HVAC", .subs = &subs_18 },
    .{ .id = 0x19, .name = "Air Conditioning" },
    .{ .id = 0x1A, .name = "Humidifier" },
    .{ .id = 0x1B, .name = "Heating", .subs = &subs_1B },
    .{ .id = 0x1C, .name = "Access Control", .subs = &subs_1C },
    .{ .id = 0x1D, .name = "Motorized Device", .subs = &subs_1D },
    .{ .id = 0x1E, .name = "Power Device", .subs = &subs_1E },
    .{ .id = 0x1F, .name = "Light Source", .subs = &subs_1F },
    .{ .id = 0x20, .name = "Window Covering", .subs = &subs_20 },
    .{ .id = 0x21, .name = "Audio Sink", .subs = &subs_21 },
    .{ .id = 0x22, .name = "Audio Source", .subs = &subs_22 },
    .{ .id = 0x23, .name = "Motorized Vehicle", .subs = &subs_23 },
    .{ .id = 0x24, .name = "Domestic Appliance", .subs = &subs_24 },
    .{ .id = 0x25, .name = "Wearable Audio Device", .subs = &subs_25 },
    .{ .id = 0x26, .name = "Aircraft", .subs = &subs_26 },
    .{ .id = 0x27, .name = "AV Equipment", .subs = &subs_27 },
    .{ .id = 0x28, .name = "Display Equipment", .subs = &subs_28 },
    .{ .id = 0x29, .name = "Hearing aid", .subs = &subs_29 },
    .{ .id = 0x2A, .name = "Gaming", .subs = &subs_2A },
    .{ .id = 0x2B, .name = "Signage", .subs = &subs_2B },
    .{ .id = 0x31, .name = "Pulse Oximeter", .subs = &subs_31 },
    .{ .id = 0x32, .name = "Weight Scale" },
    .{ .id = 0x33, .name = "Personal Mobility Device", .subs = &subs_33 },
    .{ .id = 0x34, .name = "Continuous Glucose Monitor" },
    .{ .id = 0x35, .name = "Insulin Pump", .subs = &subs_35 },
    .{ .id = 0x36, .name = "Medication Delivery" },
    .{ .id = 0x37, .name = "Spirometer", .subs = &subs_37 },
    .{ .id = 0x51, .name = "Outdoor Sports Activity", .subs = &subs_51 },
    .{ .id = 0x52, .name = "Industrial Measurement Device", .subs = &subs_52 },
    .{ .id = 0x53, .name = "Industrial Tools", .subs = &subs_53 },
    .{ .id = 0x54, .name = "Cookware Device", .subs = &subs_54 },
};

const subs_02 = [_]Sub{
    .{ .v = 0x01, .name = "Desktop Workstation" },
    .{ .v = 0x02, .name = "Server-class Computer" },
    .{ .v = 0x03, .name = "Laptop" },
    .{ .v = 0x04, .name = "Handheld PC/PDA (clamshell)" },
    .{ .v = 0x05, .name = "Palm-size PC/PDA" },
    .{ .v = 0x06, .name = "Wearable computer (watch size)" },
    .{ .v = 0x07, .name = "Tablet" },
    .{ .v = 0x08, .name = "Docking Station" },
    .{ .v = 0x09, .name = "All in One" },
    .{ .v = 0x0A, .name = "Blade Server" },
    .{ .v = 0x0B, .name = "Convertible" },
    .{ .v = 0x0C, .name = "Detachable" },
    .{ .v = 0x0D, .name = "IoT Gateway" },
    .{ .v = 0x0E, .name = "Mini PC" },
    .{ .v = 0x0F, .name = "Stick PC" },
};
const subs_03 = [_]Sub{
    .{ .v = 0x01, .name = "Sports Watch" },
    .{ .v = 0x02, .name = "Smartwatch" },
};
const subs_0C = [_]Sub{
    .{ .v = 0x01, .name = "Ear Thermometer" },
};
const subs_0D = [_]Sub{
    .{ .v = 0x01, .name = "Heart Rate Belt" },
};
const subs_0E = [_]Sub{
    .{ .v = 0x01, .name = "Arm Blood Pressure" },
    .{ .v = 0x02, .name = "Wrist Blood Pressure" },
};
const subs_0F = [_]Sub{
    .{ .v = 0x01, .name = "Keyboard" },
    .{ .v = 0x02, .name = "Mouse" },
    .{ .v = 0x03, .name = "Joystick" },
    .{ .v = 0x04, .name = "Gamepad" },
    .{ .v = 0x05, .name = "Digitizer Tablet" },
    .{ .v = 0x06, .name = "Card Reader" },
    .{ .v = 0x07, .name = "Digital Pen" },
    .{ .v = 0x08, .name = "Barcode Scanner" },
    .{ .v = 0x09, .name = "Touchpad" },
    .{ .v = 0x0A, .name = "Presentation Remote" },
};
const subs_11 = [_]Sub{
    .{ .v = 0x01, .name = "In-Shoe Running Walking Sensor" },
    .{ .v = 0x02, .name = "On-Shoe Running Walking Sensor" },
    .{ .v = 0x03, .name = "On-Hip Running Walking Sensor" },
};
const subs_12 = [_]Sub{
    .{ .v = 0x01, .name = "Cycling Computer" },
    .{ .v = 0x02, .name = "Speed Sensor" },
    .{ .v = 0x03, .name = "Cadence Sensor" },
    .{ .v = 0x04, .name = "Power Sensor" },
    .{ .v = 0x05, .name = "Speed and Cadence Sensor" },
};
const subs_13 = [_]Sub{
    .{ .v = 0x01, .name = "Switch" },
    .{ .v = 0x02, .name = "Multi-switch" },
    .{ .v = 0x03, .name = "Button" },
    .{ .v = 0x04, .name = "Slider" },
    .{ .v = 0x05, .name = "Rotary Switch" },
    .{ .v = 0x06, .name = "Touch Panel" },
    .{ .v = 0x07, .name = "Single Switch" },
    .{ .v = 0x08, .name = "Double Switch" },
    .{ .v = 0x09, .name = "Triple Switch" },
    .{ .v = 0x0A, .name = "Battery Switch" },
    .{ .v = 0x0B, .name = "Energy Harvesting Switch" },
    .{ .v = 0x0C, .name = "Push Button" },
    .{ .v = 0x0D, .name = "Dial" },
};
const subs_14 = [_]Sub{
    .{ .v = 0x01, .name = "Access Point" },
    .{ .v = 0x02, .name = "Mesh Device" },
    .{ .v = 0x03, .name = "Mesh Network Proxy" },
};
const subs_15 = [_]Sub{
    .{ .v = 0x01, .name = "Motion Sensor" },
    .{ .v = 0x02, .name = "Air quality Sensor" },
    .{ .v = 0x03, .name = "Temperature Sensor" },
    .{ .v = 0x04, .name = "Humidity Sensor" },
    .{ .v = 0x05, .name = "Leak Sensor" },
    .{ .v = 0x06, .name = "Smoke Sensor" },
    .{ .v = 0x07, .name = "Occupancy Sensor" },
    .{ .v = 0x08, .name = "Contact Sensor" },
    .{ .v = 0x09, .name = "Carbon Monoxide Sensor" },
    .{ .v = 0x0A, .name = "Carbon Dioxide Sensor" },
    .{ .v = 0x0B, .name = "Ambient Light Sensor" },
    .{ .v = 0x0C, .name = "Energy Sensor" },
    .{ .v = 0x0D, .name = "Color Light Sensor" },
    .{ .v = 0x0E, .name = "Rain Sensor" },
    .{ .v = 0x0F, .name = "Fire Sensor" },
    .{ .v = 0x10, .name = "Wind Sensor" },
    .{ .v = 0x11, .name = "Proximity Sensor" },
    .{ .v = 0x12, .name = "Multi-Sensor" },
    .{ .v = 0x13, .name = "Flush Mounted Sensor" },
    .{ .v = 0x14, .name = "Ceiling Mounted Sensor" },
    .{ .v = 0x15, .name = "Wall Mounted Sensor" },
    .{ .v = 0x16, .name = "Multisensor" },
    .{ .v = 0x17, .name = "Energy Meter" },
    .{ .v = 0x18, .name = "Flame Detector" },
    .{ .v = 0x19, .name = "Vehicle Tire Pressure Sensor" },
};
const subs_16 = [_]Sub{
    .{ .v = 0x01, .name = "Wall Light" },
    .{ .v = 0x02, .name = "Ceiling Light" },
    .{ .v = 0x03, .name = "Floor Light" },
    .{ .v = 0x04, .name = "Cabinet Light" },
    .{ .v = 0x05, .name = "Desk Light" },
    .{ .v = 0x06, .name = "Troffer Light" },
    .{ .v = 0x07, .name = "Pendant Light" },
    .{ .v = 0x08, .name = "In-ground Light" },
    .{ .v = 0x09, .name = "Flood Light" },
    .{ .v = 0x0A, .name = "Underwater Light" },
    .{ .v = 0x0B, .name = "Bollard with Light" },
    .{ .v = 0x0C, .name = "Pathway Light" },
    .{ .v = 0x0D, .name = "Garden Light" },
    .{ .v = 0x0E, .name = "Pole-top Light" },
    .{ .v = 0x0F, .name = "Spotlight" },
    .{ .v = 0x10, .name = "Linear Light" },
    .{ .v = 0x11, .name = "Street Light" },
    .{ .v = 0x12, .name = "Shelves Light" },
    .{ .v = 0x13, .name = "Bay Light" },
    .{ .v = 0x14, .name = "Emergency Exit Light" },
    .{ .v = 0x15, .name = "Light Controller" },
    .{ .v = 0x16, .name = "Light Driver" },
    .{ .v = 0x17, .name = "Bulb" },
    .{ .v = 0x18, .name = "Low-bay Light" },
    .{ .v = 0x19, .name = "High-bay Light" },
};
const subs_17 = [_]Sub{
    .{ .v = 0x01, .name = "Ceiling Fan" },
    .{ .v = 0x02, .name = "Axial Fan" },
    .{ .v = 0x03, .name = "Exhaust Fan" },
    .{ .v = 0x04, .name = "Pedestal Fan" },
    .{ .v = 0x05, .name = "Desk Fan" },
    .{ .v = 0x06, .name = "Wall Fan" },
};
const subs_18 = [_]Sub{
    .{ .v = 0x01, .name = "Thermostat" },
    .{ .v = 0x02, .name = "Humidifier" },
    .{ .v = 0x03, .name = "De-humidifier" },
    .{ .v = 0x04, .name = "Heater" },
    .{ .v = 0x05, .name = "Radiator" },
    .{ .v = 0x06, .name = "Boiler" },
    .{ .v = 0x07, .name = "Heat Pump" },
    .{ .v = 0x08, .name = "Infrared Heater" },
    .{ .v = 0x09, .name = "Radiant Panel Heater" },
    .{ .v = 0x0A, .name = "Fan Heater" },
    .{ .v = 0x0B, .name = "Air Curtain" },
};
const subs_1B = [_]Sub{
    .{ .v = 0x01, .name = "Radiator" },
    .{ .v = 0x02, .name = "Boiler" },
    .{ .v = 0x03, .name = "Heat Pump" },
    .{ .v = 0x04, .name = "Infrared Heater" },
    .{ .v = 0x05, .name = "Radiant Panel Heater" },
    .{ .v = 0x06, .name = "Fan Heater" },
    .{ .v = 0x07, .name = "Air Curtain" },
};
const subs_1C = [_]Sub{
    .{ .v = 0x01, .name = "Access Door" },
    .{ .v = 0x02, .name = "Garage Door" },
    .{ .v = 0x03, .name = "Emergency Exit Door" },
    .{ .v = 0x04, .name = "Access Lock" },
    .{ .v = 0x05, .name = "Elevator" },
    .{ .v = 0x06, .name = "Window" },
    .{ .v = 0x07, .name = "Entrance Gate" },
    .{ .v = 0x08, .name = "Door Lock" },
    .{ .v = 0x09, .name = "Locker" },
};
const subs_1D = [_]Sub{
    .{ .v = 0x01, .name = "Motorized Gate" },
    .{ .v = 0x02, .name = "Awning" },
    .{ .v = 0x03, .name = "Blinds or Shades" },
    .{ .v = 0x04, .name = "Curtains" },
    .{ .v = 0x05, .name = "Screen" },
};
const subs_1E = [_]Sub{
    .{ .v = 0x01, .name = "Power Outlet" },
    .{ .v = 0x02, .name = "Power Strip" },
    .{ .v = 0x03, .name = "Plug" },
    .{ .v = 0x04, .name = "Power Supply" },
    .{ .v = 0x05, .name = "LED Driver" },
    .{ .v = 0x06, .name = "Fluorescent Lamp Gear" },
    .{ .v = 0x07, .name = "HID Lamp Gear" },
    .{ .v = 0x08, .name = "Charge Case" },
    .{ .v = 0x09, .name = "Power Bank" },
};
const subs_1F = [_]Sub{
    .{ .v = 0x01, .name = "Incandescent Light Bulb" },
    .{ .v = 0x02, .name = "LED Lamp" },
    .{ .v = 0x03, .name = "HID Lamp" },
    .{ .v = 0x04, .name = "Fluorescent Lamp" },
    .{ .v = 0x05, .name = "LED Array" },
    .{ .v = 0x06, .name = "Multi-Color LED Array" },
    .{ .v = 0x07, .name = "Low voltage halogen" },
    .{ .v = 0x08, .name = "Organic light emitting diode (OLED)" },
};
const subs_20 = [_]Sub{
    .{ .v = 0x01, .name = "Window Shades" },
    .{ .v = 0x02, .name = "Window Blinds" },
    .{ .v = 0x03, .name = "Window Awning" },
    .{ .v = 0x04, .name = "Window Curtain" },
    .{ .v = 0x05, .name = "Exterior Shutter" },
    .{ .v = 0x06, .name = "Exterior Screen" },
};
const subs_21 = [_]Sub{
    .{ .v = 0x01, .name = "Standalone Speaker" },
    .{ .v = 0x02, .name = "Soundbar" },
    .{ .v = 0x03, .name = "Bookshelf Speaker" },
    .{ .v = 0x04, .name = "Standmounted Speaker" },
    .{ .v = 0x05, .name = "Speakerphone" },
};
const subs_22 = [_]Sub{
    .{ .v = 0x01, .name = "Microphone" },
    .{ .v = 0x02, .name = "Alarm" },
    .{ .v = 0x03, .name = "Bell" },
    .{ .v = 0x04, .name = "Horn" },
    .{ .v = 0x05, .name = "Broadcasting Device" },
    .{ .v = 0x06, .name = "Service Desk" },
    .{ .v = 0x07, .name = "Kiosk" },
    .{ .v = 0x08, .name = "Broadcasting Room" },
    .{ .v = 0x09, .name = "Auditorium" },
};
const subs_23 = [_]Sub{
    .{ .v = 0x01, .name = "Car" },
    .{ .v = 0x02, .name = "Large Goods Vehicle" },
    .{ .v = 0x03, .name = "2-Wheeled Vehicle" },
    .{ .v = 0x04, .name = "Motorbike" },
    .{ .v = 0x05, .name = "Scooter" },
    .{ .v = 0x06, .name = "Moped" },
    .{ .v = 0x07, .name = "3-Wheeled Vehicle" },
    .{ .v = 0x08, .name = "Light Vehicle" },
    .{ .v = 0x09, .name = "Quad Bike" },
    .{ .v = 0x0A, .name = "Minibus" },
    .{ .v = 0x0B, .name = "Bus" },
    .{ .v = 0x0C, .name = "Trolley" },
    .{ .v = 0x0D, .name = "Agricultural Vehicle" },
    .{ .v = 0x0E, .name = "Camper / Caravan" },
    .{ .v = 0x0F, .name = "Recreational Vehicle / Motor Home" },
};
const subs_24 = [_]Sub{
    .{ .v = 0x01, .name = "Refrigerator" },
    .{ .v = 0x02, .name = "Freezer" },
    .{ .v = 0x03, .name = "Oven" },
    .{ .v = 0x04, .name = "Microwave" },
    .{ .v = 0x05, .name = "Toaster" },
    .{ .v = 0x06, .name = "Washing Machine" },
    .{ .v = 0x07, .name = "Dryer" },
    .{ .v = 0x08, .name = "Coffee maker" },
    .{ .v = 0x09, .name = "Clothes iron" },
    .{ .v = 0x0A, .name = "Curling iron" },
    .{ .v = 0x0B, .name = "Hair dryer" },
    .{ .v = 0x0C, .name = "Vacuum cleaner" },
    .{ .v = 0x0D, .name = "Robotic vacuum cleaner" },
    .{ .v = 0x0E, .name = "Rice cooker" },
    .{ .v = 0x0F, .name = "Clothes steamer" },
};
const subs_25 = [_]Sub{
    .{ .v = 0x01, .name = "Earbud" },
    .{ .v = 0x02, .name = "Headset" },
    .{ .v = 0x03, .name = "Headphones" },
    .{ .v = 0x04, .name = "Neck Band" },
    .{ .v = 0x05, .name = "Left Earbud" },
    .{ .v = 0x06, .name = "Right Earbud" },
};
const subs_26 = [_]Sub{
    .{ .v = 0x01, .name = "Light Aircraft" },
    .{ .v = 0x02, .name = "Microlight" },
    .{ .v = 0x03, .name = "Paraglider" },
    .{ .v = 0x04, .name = "Large Passenger Aircraft" },
};
const subs_27 = [_]Sub{
    .{ .v = 0x01, .name = "Amplifier" },
    .{ .v = 0x02, .name = "Receiver" },
    .{ .v = 0x03, .name = "Radio" },
    .{ .v = 0x04, .name = "Tuner" },
    .{ .v = 0x05, .name = "Turntable" },
    .{ .v = 0x06, .name = "CD Player" },
    .{ .v = 0x07, .name = "DVD Player" },
    .{ .v = 0x08, .name = "Bluray Player" },
    .{ .v = 0x09, .name = "Optical Disc Player" },
    .{ .v = 0x0A, .name = "Set-Top Box" },
};
const subs_28 = [_]Sub{
    .{ .v = 0x01, .name = "Television" },
    .{ .v = 0x02, .name = "Monitor" },
    .{ .v = 0x03, .name = "Projector" },
};
const subs_29 = [_]Sub{
    .{ .v = 0x01, .name = "In-ear hearing aid" },
    .{ .v = 0x02, .name = "Behind-ear hearing aid" },
    .{ .v = 0x03, .name = "Cochlear Implant" },
};
const subs_2A = [_]Sub{
    .{ .v = 0x01, .name = "Home Video Game Console" },
    .{ .v = 0x02, .name = "Portable handheld console" },
};
const subs_2B = [_]Sub{
    .{ .v = 0x01, .name = "Digital Signage" },
    .{ .v = 0x02, .name = "Electronic Label" },
};
const subs_31 = [_]Sub{
    .{ .v = 0x01, .name = "Fingertip Pulse Oximeter" },
    .{ .v = 0x02, .name = "Wrist Worn Pulse Oximeter" },
};
const subs_33 = [_]Sub{
    .{ .v = 0x01, .name = "Powered Wheelchair" },
    .{ .v = 0x02, .name = "Mobility Scooter" },
};
const subs_35 = [_]Sub{
    .{ .v = 0x01, .name = "Insulin Pump, durable pump" },
    .{ .v = 0x04, .name = "Insulin Pump, patch pump" },
    .{ .v = 0x08, .name = "Insulin Pen" },
};
const subs_37 = [_]Sub{
    .{ .v = 0x01, .name = "Handheld Spirometer" },
};
const subs_51 = [_]Sub{
    .{ .v = 0x01, .name = "Location Display" },
    .{ .v = 0x02, .name = "Location and Navigation Display" },
    .{ .v = 0x03, .name = "Location Pod" },
    .{ .v = 0x04, .name = "Location and Navigation Pod" },
};
const subs_52 = [_]Sub{
    .{ .v = 0x01, .name = "Torque Testing Device" },
    .{ .v = 0x02, .name = "Caliper" },
    .{ .v = 0x03, .name = "Dial Indicator" },
    .{ .v = 0x04, .name = "Micrometer" },
    .{ .v = 0x05, .name = "Height Gauge" },
    .{ .v = 0x06, .name = "Force Gauge" },
};
const subs_53 = [_]Sub{
    .{ .v = 0x01, .name = "Machine Tool Holder" },
    .{ .v = 0x02, .name = "Generic Clamping Device" },
    .{ .v = 0x03, .name = "Clamping Jaws/Jaw Chuck" },
    .{ .v = 0x04, .name = "Clamping (Collet) Chuck" },
    .{ .v = 0x05, .name = "Clamping Mandrel" },
    .{ .v = 0x06, .name = "Vise" },
    .{ .v = 0x07, .name = "Zero-Point Clamping System" },
    .{ .v = 0x08, .name = "Torque Wrench" },
    .{ .v = 0x09, .name = "Torque Screwdriver" },
};
const subs_54 = [_]Sub{
    .{ .v = 0x01, .name = "Pot and Jugs" },
    .{ .v = 0x02, .name = "Pressure Cooker" },
    .{ .v = 0x03, .name = "Slow Cooker" },
    .{ .v = 0x04, .name = "Steam Cooker" },
    .{ .v = 0x05, .name = "Saucepan" },
    .{ .v = 0x06, .name = "Frying Pan" },
    .{ .v = 0x07, .name = "Casserole" },
    .{ .v = 0x08, .name = "Dutch Oven" },
    .{ .v = 0x09, .name = "Grill Pan/Raclette Grill/Griddle Pan" },
    .{ .v = 0x0A, .name = "Braising Pan" },
    .{ .v = 0x0B, .name = "Wok Pan" },
    .{ .v = 0x0C, .name = "Paella Pan" },
    .{ .v = 0x0D, .name = "Crepe Pan" },
    .{ .v = 0x0E, .name = "Tagine" },
    .{ .v = 0x0F, .name = "Fondue" },
    .{ .v = 0x10, .name = "Lid" },
    .{ .v = 0x11, .name = "Wired Probe" },
    .{ .v = 0x12, .name = "Wireless Probe" },
    .{ .v = 0x13, .name = "Baking Molds" },
    .{ .v = 0x14, .name = "Baking Tray" },
};

/// Subcategory table flattened: (category, value) -> name.
pub const SubRef = struct { cat: u8, v: u8, name: []const u8 };

pub const sub_table = [_]SubRef{
    .{ .cat = 0x02, .v = 0x01, .name = "Desktop Workstation" },
    .{ .cat = 0x02, .v = 0x03, .name = "Laptop" },
    .{ .cat = 0x02, .v = 0x07, .name = "Tablet" },
};

pub fn category(id: u8) ?[]const u8 {
    for (categories) |c| {
        if (c.id == id) return c.name;
    }
    return null;
}

/// "Watch" / "Sports Watch" for a raw appearance value.
pub fn nameFor(appearance: u16) []const u8 {
    const cat: u8 = @intCast((appearance >> 6) & 0xFF); // clamp: raw device data
    const sub: u8 = @intCast(appearance & 0x3F);
    const c = category(cat) orelse return "unknown";
    if (sub == 0) return c;
    for (subsOf(cat)) |s| {
        if (s.v == sub) return s.name;
    }
    return c;
}

/// Subcategories attached to a category (finds the declaration by id).
pub fn subsOf(cat: u8) []const Sub {
    for (categories) |c| {
        if (c.id == cat) return c.subs;
    }
    return &.{};
}

test "appearance lookup" {
    try std.testing.expectEqualStrings("Unknown", nameFor(0));
    try std.testing.expectEqualStrings("Phone", nameFor(0x0040));
    try std.testing.expectEqualStrings("Computer", nameFor(0x0080));
    try std.testing.expectEqualStrings("Laptop", nameFor((0x02 << 6) | 0x03));
    try std.testing.expectEqualStrings("Watch", nameFor(0x00C0));
    try std.testing.expectEqualStrings("Thermometer", nameFor(0x0300));
    try std.testing.expectEqualStrings("Human Interface Device", nameFor(0x03C0));
    try std.testing.expectEqualStrings("Keyboard", nameFor((0x03C0 >> 6 << 6) | 0x01));
}

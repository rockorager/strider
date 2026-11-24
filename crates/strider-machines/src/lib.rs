//! Strider's behavior as plusthree statecharts. A machine's context holds small control
//! data; events come in, its effects (`*Fx` enums) go out, and it does no I/O. The app
//! carries out the effects and draws what the snapshots say.

pub mod driver;
pub mod drives;
pub mod folder;
pub mod keymap;
pub mod mode;
pub mod operation;
pub mod preview;

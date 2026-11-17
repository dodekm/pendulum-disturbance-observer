
#include "AeroShield.h"


#define MIN(a, b) ((a) < (b) ? (a) : (b))
#define MAX(a, b) ((a) > (b) ? (a) : (b))

static void timer_callback();

bool AeroClass::begin(float Ts) {
  this->Ts = Ts;
  bool res;

  pinMode(MPIN,OUTPUT);
  digitalWrite(MPIN,0);
  pinMode(M_REV_PIN,OUTPUT);
  digitalWrite(M_REV_PIN,0); 
  delay(3000);  

  motor.attach(MPIN);
  motor_rev.attach(M_REV_PIN);

  IRQn_Type irq;

  if (TIMER_SERVO == TIM2) irq = TIM2_IRQn;
#if defined(TIM3)
  else if (TIMER_SERVO == TIM3) irq = TIM3_IRQn;
#endif
#if defined(TIM6)
  else if (TIMER_SERVO == TIM6) irq = TIM6_IRQn;
#endif
#if defined(TIM7)
  else if (TIMER_SERVO == TIM7) irq = TIM7_IRQn;
#endif

  HAL_NVIC_SetPriority(irq, 0, 0);

  motor.write(0);
  motor_rev.write(0);
  delay(5000);
  Wire.begin();
  Wire.setClock(400000);
  res = as5600.begin();
  if (!res) return res;
  res = as5600.detectMagnet();
  if (!res) return res;
  as5600.setOffset(0);
  calibrate();
  delay(200);
  if (Ts > 0.0) {
    timer.pause();
    timer.setOverflow(Ts * 1e6, MICROSEC_FORMAT); 
    timer.attachInterrupt(timer_callback);
    timer.refresh();
    timer.resume();
  }
  actuatorWrite(0);
  return res;
}

void AeroClass::begin_throttle_calibrate() {
  
  motor.attach(MPIN);
  motor_rev.attach(M_REV_PIN);
  motor_rev.write(0);

  IRQn_Type irq;

  if (TIMER_SERVO == TIM2) irq = TIM2_IRQn;
#if defined(TIM3)
  else if (TIMER_SERVO == TIM3) irq = TIM3_IRQn;
#endif
#if defined(TIM6)
  else if (TIMER_SERVO == TIM6) irq = TIM6_IRQn;
#endif
#if defined(TIM7)
  else if (TIMER_SERVO == TIM7) irq = TIM7_IRQn;
#endif

  HAL_NVIC_SetPriority(irq, 0, 0);

  motor.write(180);
  delay(4000);
  motor.write(0);
  delay(4000);

}

void AeroClass::calibrate(void) {
  _zero = as5600.getCumulativePosition();
}


void AeroClass::actuatorWrite(float percentValue) {

  percentValue = MAX(percentValue, -100);
  percentValue = MIN(percentValue, 100);

  if (percentValue >= 0.0) {
    
    int pwm_angle = (int)mapFloat(percentValue, 0.0, 100, 10, 180.0);
    motor.write(pwm_angle);
    motor_rev.write(0);
  } else {
    int pwm_angle = (int)mapFloat(-percentValue, 0.0, 100, 80.0, 120.0);
    motor_rev.write(pwm_angle);
    motor.write(0);
  }
}



float AeroClass::sensorReadDegree() {
  int32_t angle = as5600.getCumulativePosition();
  float deg = -(angle - _zero) * AS5600_RAW_TO_DEGREES;
  return deg;
}

float AeroClass::sensorReadDegreeSampled() {
  return y_sampler.read();
}


float AeroClass::mapFloat(float x, float in_min, float in_max, float out_min, float out_max) {
  return (x - in_min) * (out_max - out_min) / (in_max - in_min) + out_min;
}

class AeroClass_ : public AeroClass {

public:
  void timer_tick() {
    y_sampler.sample(sensorReadDegree());
    tick++;
  }
};


AeroClass_ AeroShield_;
AeroClass& AeroShield = AeroShield_;

static void timer_callback() {
  AeroShield_.timer_tick();
}

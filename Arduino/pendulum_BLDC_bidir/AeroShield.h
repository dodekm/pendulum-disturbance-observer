
#pragma once
            
#include <Arduino.h>			
#include "src\AS5600\AS5600.h"

#include <Servo.h>  
         

template<typename T>
class Sampler
{
public:
    void sample(const T& value_) {
        value = value_;
        missed = available;
        available = true;
    }

    bool isAvailable() const {
        return available;
    }

    bool isMissed() const {
        return missed;
    }

    T read() {
        available = false;
        missed = false;
        return value;
    }
    void read(T& value_) {
        available = false;
        missed = false;
        value_=value;
    }

    T getLastValue() const {
        return value;
    }

private:
    volatile T value{};               // Default-initialize value
    volatile bool available = false;
    volatile bool missed = false;
};

class AeroClass{		    	                         
 
 public:
  AeroClass():timer(TIM1){}
  bool begin(float); 
  void begin_throttle_calibrate();                                           
  void actuatorWrite(float);      

  float sensorReadDegree(void); 
  float sensorReadDegreeSampled(void);    
  bool isSampleAvailable(){return y_sampler.isAvailable();}               
  void calibrate(void);
  unsigned long getTick(){return tick;}
 
protected:

  Sampler<float> y_sampler;
  unsigned long tick=0;
   
 private: 
                         
   float mapFloat(float , float , float , float , float );
   int32_t _zero;
   static constexpr int MPIN=6;   
   static constexpr int M_REV_PIN=5;   
   
  float Ts=0.05; 
  AS5600 as5600;
  Servo motor;
  Servo motor_rev;
  HardwareTimer timer; 
   
};

extern AeroClass& AeroShield; 


